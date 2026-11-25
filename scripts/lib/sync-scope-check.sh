#!/usr/bin/env bash
set -euo pipefail
# sync-scope-check.sh — the sync-PR SCOPE guard (issue #1700 AC1, #1523 post-mortem).
#
# #1523 was closed as unsafe-to-merge after surviving three weeks / 255 commits:
# a generated sync PR that claimed to sync three workflow stubs had, under
# automation, also touched package.json (the deliberately-absent trunk-corruption
# signature #1485/#1519), prompts/**, evals/** and scripts/**. Nothing failed it.
#
# This library is the mechanical net: a GENERATED sync PR records the exact set
# of paths it intends to sync, and a required CI check fails the PR when its diff
# touches any path OUTSIDE that declared set. The matching is pure/deterministic
# (literal + glob, no model involvement) so a mechanical failure is caught by a
# mechanical guard.
#
# It is a set of PURE functions; the network side (fetching PR body/labels/files
# and failing the check) is the caller's job (scripts/sync-scope-guard.sh).
#
#   sync_extract_declared_paths            (reads PR body on stdin)
#     Print one declared path per line from the body's declared-paths marker
#     block; nothing when the body has no marker.
#   is_generated_sync_pr <labels> <body>
#     Exit 0 when the PR is a generated sync PR — it carries the sync label OR
#     the declared-paths marker — so the guard enforces only on generated PRs,
#     never on human PRs (AC#4). Exit 1 otherwise.
#   sync_scope_violations <declared_nl> <changed_nl>
#     Print each changed path NOT covered by the declared set (literal or glob),
#     one per line; empty output when every changed path is in scope.

# The declared set lives in the PR body between these markers (an HTML comment
# so it is invisible in the rendered PR yet machine-readable — GitHub search
# cannot index it, matching the repo's other body-marker conventions).
SYNC_SCOPE_MARKER_BEGIN='<!-- standards-sync:declared-paths'
SYNC_SCOPE_MARKER_END='-->'

# The label the sync generator applies; a PR carrying it is a generated sync PR.
: "${SYNC_SCOPE_LABEL:=standards-sync}"

# _sync_trim <string>
#   Strip leading/trailing whitespace. Declared paths and labels are compared
#   literally, so surrounding whitespace must not create a spurious mismatch.
_sync_trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# sync_extract_declared_paths            (PR body on stdin)
#   Emit the declared paths from the marker block. Lines strictly between the
#   begin marker and the next end marker are the declared set; blank lines are
#   ignored so the block can be formatted for readability.
sync_extract_declared_paths() {
  local line trimmed in_block=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [ "$in_block" -eq 0 ]; then
      case "$line" in
        *"$SYNC_SCOPE_MARKER_BEGIN"*) in_block=1 ;;
      esac
      continue
    fi
    case "$line" in
      *"$SYNC_SCOPE_MARKER_END"*) break ;;
    esac
    trimmed=$(_sync_trim "$line")
    [[ -n "$trimmed" ]] && printf '%s\n' "$trimmed"
  done
  return 0
}

# is_generated_sync_pr <labels_newline> <body>
#   A generated sync PR is identified by its automation marker: the sync label
#   (primary) or the declared-paths body marker (fallback). Human PRs have
#   neither and are therefore never enforced (AC#4).
is_generated_sync_pr() {
  local labels="${1:-}" body="${2:-}" label trimmed
  while IFS= read -r label; do
    trimmed=$(_sync_trim "$label")
    [[ "$trimmed" = "$SYNC_SCOPE_LABEL" ]] && return 0
  done <<< "$labels"
  case "$body" in
    *"$SYNC_SCOPE_MARKER_BEGIN"*) return 0 ;;
  esac
  return 1
}

# _sync_path_matches <path> <pattern>
#   True when <path> is covered by <pattern>. An exact literal match always
#   counts; otherwise the pattern is applied as a bash glob (unquoted RHS of
#   [[ == ]], where `*` spans `/`), so a declared `prompts/**` or `dir/*` covers
#   nested paths. Deterministic: no external process, no model.
_sync_path_matches() {
  local path="$1" pattern="$2"
  [[ "$path" = "$pattern" ]] && return 0
  # shellcheck disable=SC2053  # intentional glob match: RHS must stay unquoted
  [[ "$path" == $pattern ]]
}

# sync_scope_violations <declared_newline> <changed_newline>
#   Print each changed path not covered by any declared pattern. Empty declared
#   set => every changed path is a violation (a sync PR that declared nothing
#   must not pass silently). Empty changed set => no violations.
sync_scope_violations() {
  local declared="${1:-}" changed="${2:-}"
  local -a patterns=()
  local line trimmed
  while IFS= read -r line; do
    trimmed=$(_sync_trim "$line")
    [[ -n "$trimmed" ]] && patterns+=("$trimmed")
  done <<< "$declared"

  local path matched pattern
  while IFS= read -r path; do
    trimmed=$(_sync_trim "$path")
    [[ -n "$trimmed" ]] || continue
    matched=0
    for pattern in ${patterns[@]+"${patterns[@]}"}; do
      if _sync_path_matches "$trimmed" "$pattern"; then
        matched=1
        break
      fi
    done
    [ "$matched" -eq 0 ] && printf '%s\n' "$trimmed"
  done <<< "$changed"
  return 0
}
