#!/usr/bin/env bash
# channel-pin-consistency.sh — same-file channel-pin/comment consistency guard
# (#1866 AC #3; regression guard for #1819).
#
# The workflow-stub sync generator (standards-deploy.yml, in the PUBLIC
# petry-projects/.github repo) PRESERVES each destination repo's own per-repo
# `uses:` channel pin. #1819 exposed the receiving-side hazard: a guard COMMENT
# (or the `agent_ref:` input) that names a channel can drift out of step with the
# actual `uses:` pin in the SAME file — moving one without the other. This library
# provides the receiving-side property this repo can enforce for its own committed
# stubs: any channel a caller stub's comments / `agent_ref` name for its OWN
# reusable must equal the `uses:` pin in the same file.
#
# It is a member of the receiving-guard family (validate-caller-inputs #1253,
# caller-stub-freeze #1255, sync-scope-guard #1700, self-review-channel SC2 #1624).
# Intentional CONTRAST references (a promotion target, a legacy form, a different
# agent's duty) are excluded so they are not mistaken for a stale pin comment.
#
# Pure helpers, no side effects, no network. This file defines functions only (no
# top-level `set -euo pipefail`), matching the repo's sourceable-lib convention
# (e.g. scripts/lib/self-review-channel.sh, which it sources for the shared
# `src_stub_uses_ref` / `src_stub_agent_ref` parsers).
#
# Sourced by tests/test_channel_pin_consistency.bats.

CPC_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/self-review-channel.sh
source "${CPC_LIB_DIR}/self-review-channel.sh"

# Contrast markers: words that flag a comment line as INTENTIONALLY naming a
# channel other than this file's own pin — a promotion target, a legacy/pre-#1184
# form, a cross-agent duty note, or an explicit dogfood/canary contrast — so it is
# not mistaken for a stale/inconsistent pin comment.
CPC_CONTRAST_RE='legacy|promote|promoted|promotion|fleet|pre-#|independent|on purpose|instead|rather than|formerly|dogfood'

# cpc_channel_refs
#   Read text on stdin; emit each `<agent>/<channel>` channel ref it contains, one
#   per line (deduped, in first-seen order). A channel ref is `<agent>/(vN-)?<tier>`
#   with tier ∈ {stable, next, ring<N>}; the agent token is lowercase/hyphenated.
#   A full `…/<workflow>.yml@<agent>/<channel>` token yields just `<agent>/<channel>`
#   (the `.` in `.yml` bounds the agent). Bare tiers with no agent and ordinary
#   paths yield nothing. Always returns 0.
cpc_channel_refs() {
  grep -oE '[a-z][a-z0-9-]*/(v[0-9]+-)?(stable|next|ring[0-9]+)([^a-z0-9-]|$)' \
    | sed -E 's/[^a-z0-9-]$//' \
    | awk 'NF && !seen[$0]++'
}

# cpc_line_is_contrast <text>
#   Return 0 iff <text> carries a contrast marker (see CPC_CONTRAST_RE).
cpc_line_is_contrast() {
  printf '%s' "$1" | grep -qiE "$CPC_CONTRAST_RE"
}

# cpc_stub_conflicts <file>
#   Print each same-file channel-pin conflict in <file>, one per line; return 1 if
#   any are found, else 0. Two conflict classes:
#     (a) a COMMENT names this file's OWN agent at a channel != the `uses:` pin,
#         on a line that is not a contrast reference;
#     (b) the `agent_ref:` input names a channel != the `uses:` pin.
#   A file with no reusable `uses:` channel pin has nothing to check → returns 0
#   with no output (not-applicable).
cpc_stub_conflicts() {
  local file="$1" pinref pinagent pinchan aref line comment ref agent chan found=0
  pinref="$(src_stub_uses_ref "$file")" || return 0   # no pin → N/A
  case "$pinref" in
    */*) ;;                                            # need an <agent>/<channel> pin
    *) return 0 ;;                                     # e.g. @main / a SHA → N/A
  esac
  pinagent="${pinref%/*}"
  pinchan="${pinref##*/}"

  # (a) comment/pin consistency.
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      *"#"*) comment="${line#*#}" ;;                   # text after the first '#'
      *) continue ;;
    esac
    cpc_line_is_contrast "$comment" && continue
    while IFS= read -r ref; do
      agent="${ref%/*}"
      chan="${ref##*/}"
      if [ "$agent" = "$pinagent" ] && [ "$chan" != "$pinchan" ]; then
        printf 'comment names channel `%s` but `uses:` pins `%s`\n' "$ref" "$pinref"
        found=1
      fi
    done < <(printf '%s\n' "$comment" | cpc_channel_refs)
  done < "$file"

  # (b) agent_ref/uses consistency (only when an agent_ref input is present).
  if aref="$(src_stub_agent_ref "$file")"; then
    if [ "$aref" != "$pinref" ]; then
      printf '`agent_ref: %s` does not match the `uses:` pin `%s`\n' "$aref" "$pinref"
      found=1
    fi
  fi

  return "$found"
}

# cpc_assert_consistent <file> [<label>]
#   End-to-end AC #3 guard. Passes (0) a file with no channel pin (not-applicable)
#   or one whose comments AND `agent_ref` agree with the `uses:` pin. On conflict,
#   emits an actionable message naming issues #1866/#1819 and the offending refs to
#   stderr, and returns 1 — steering a contributor to fix the COMMENT/`agent_ref`
#   to match the preserved pin rather than repinning `uses:` to match the comment.
cpc_assert_consistent() {
  local file="$1" label="${2:-$1}" conflicts
  if ! src_stub_uses_ref "$file" >/dev/null 2>&1; then
    printf 'channel-pin consistency: %s has no reusable channel pin — N/A\n' "$label"
    return 0
  fi
  if conflicts="$(cpc_stub_conflicts "$file")"; then
    printf 'channel-pin consistency: %s — comments, `agent_ref`, and `uses:` pin agree — OK\n' "$label"
    return 0
  fi
  {
    printf '::error::channel-pin INCONSISTENCY in %s (issue #1866, regression of #1819):\n' "$label"
    while IFS= read -r c; do
      [ -n "$c" ] && printf '  - %s\n' "$c"
    done <<<"$conflicts"
    printf 'A guard comment or `agent_ref` in a caller stub must name the SAME channel as the\n'
    printf '`uses:` pin in the same file. The standards-sync generator preserves THIS repo'"'"'s own\n'
    printf '`uses:` channel pin, so a comment (or agent_ref) naming a different channel is stale —\n'
    printf 'fix the COMMENT / `agent_ref` to match the pin; do NOT repin `uses:` to match the\n'
    printf 'comment. If a line is an intentional contrast reference (a promotion target, a legacy\n'
    printf 'form, or a different agent'"'"'s duty), mark it (e.g. "promoted", "legacy", "fleet"). See #1866.\n'
  } >&2
  return 1
}
