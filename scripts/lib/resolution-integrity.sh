#!/usr/bin/env bash
# resolution-integrity.sh — the pure predicate gating review-thread resolution on
# an actual head-SHA change (#1609, slice 1 of 2).
#
# Third occurrence of the "threads resolved with no work" class, and the first to
# defeat the shipped gate: on petry-projects/.github#1024 all 18 open threads —
# including a Critical unmatched-brace finding on scripts/apply-repo-settings.sh —
# went to resolved between 14:00Z and 14:03Z with NO commit at all (head unchanged
# at 30375c5c). The #1567/#1604 fix only put an evidence bar on the `status=applied`
# claim; it never gated thread resolution, and the resolve_* nets in
# dev-lead-fix-reviews.sh run in the no-changes path too — so a reply marker alone
# (resolve_addressed_bot_threads, #1547) resolved the Critical thread.
#
# This helper is deliberately PURE: no network, no git, no gh, no sourcing of other
# dev-lead libs. That is what makes it exhaustively unit-testable in isolation and
# keeps slice 2 (#1617, the wiring into the resolve_* call sites) small. It is
# sourced under `set -euo pipefail`, so it only `return`s — it never `exit`s.

# ri_may_resolve <sha_before> <sha_after>
# The head-movement predicate for thread resolution. Fails closed: returns 0 (may
# resolve) ONLY when both arguments are non-empty AND they differ — i.e. the head
# actually moved between the pre- and post-work snapshots. Every other case —
# either argument empty, both empty, or the two equal — returns non-zero (must not
# resolve), which is precisely the #1024 no-commit vector. Emits nothing.
ri_may_resolve() {
  local sha_before="${1:-}" sha_after="${2:-}"
  [[ -n "$sha_before" ]] || return 1
  [[ -n "$sha_after" ]] || return 1
  [[ "$sha_before" != "$sha_after" ]] || return 1
  return 0
}
