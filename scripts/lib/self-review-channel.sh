#!/usr/bin/env bash
# self-review-channel.sh — SC2 self-review-duty channel-tier guard (#1624).
#
# Safe Release SC2 (epic #495 / story #503): a deliberately-broken in-development
# version of this repo's agentic review/merge duty must NOT be able to block the
# PR that fixes its own breakage. For `.github-private`'s dev/merge duty the
# structural property that guarantees this is that `dev-lead.yml` pins its
# reusable to a **promoted** channel — ring<N> or stable; `@dev-lead/v139-ring0`
# since #2091 — even though this repo sits in ring `next`, so a broken `next`
# cannot, by construction, gate its own fix, and a bad promoted tier is rolled
# back by moving its tag. This is the sanctioned SC2 exception the `pinned-version-report`
# ring-mismatch flag calls out (see docs/release/versioning.md,
# docs/initiatives/agentic-release-strategy.md).
#
# These are pure helpers with no side effects and no network: they parse the
# `uses:` channel pin from a caller stub and classify its TIER. A "promoted"
# tier means the channel tier, not a literal string — `v1-ring0`, `ring1`,
# `v1-stable` and the legacy bare `stable` qualify; `v1-next`, `next`, `@main`,
# and bare SHAs do not. (src_is_stable_tier still answers the narrower question.)
#
# Sourced by tests/test_sc2_self_review_channel.bats. This file defines functions
# only (no top-level `set -euo pipefail`), matching the repo's sourceable-lib
# convention (e.g. scripts/lib/holdout-guard.sh).

# src_stub_uses_ref <stub_file>
#   Echo the ref of the first reusable-workflow caller pin — the token after the
#   final `@` on a `uses: …/<workflow>.yml@<ref>` line — with the trailing inline
#   `# NOSONAR …` comment and surrounding whitespace stripped. Returns non-zero
#   if the file has no such pin.
src_stub_uses_ref() {
  local file="$1" line stripped ref content
  [[ -f "$file" ]] || return 1
  content="$(grep -E '^[[:space:]]*uses:[[:space:]]*[^[:space:]#]+\.yml@' "$file")" || true
  line="${content%%$'\n'*}"               # first matching line, no pipe to head (avoids SIGPIPE under pipefail)
  [[ -n "$line" ]] || return 1
  stripped="${line%%#*}"                 # drop any inline comment
  read -r ref <<<"${stripped##*@}"       # token after the last @, whitespace-trimmed
  [[ -n "$ref" ]] || return 1
  printf '%s\n' "$ref"
}

# src_stub_agent_ref <stub_file>
#   Echo the value of the caller's `agent_ref:` input — the token after
#   `agent_ref:` — with any inline comment and surrounding whitespace stripped.
#   Returns non-zero if the file declares no such input. This is the ref
#   dev-lead's own scripts/prompts are CHECKED OUT from (dev-lead-reusable.yml
#   `inputs.agent_ref`, consumed at the `ref:` of its `actions/checkout` steps),
#   so for the SC2 duty it must be a promoted tier just like the `uses:` pin — a
#   promoted reusable driven by a `next` `agent_ref` would still run the actual
#   review/merge logic from an unsafe channel.
src_stub_agent_ref() {
  local file="$1" line stripped ref content
  [[ -f "$file" ]] || return 1
  content="$(grep -E '^[[:space:]]*agent_ref:[[:space:]]*[^[:space:]#]' "$file")" || true
  line="${content%%$'\n'*}"               # first matching line, no pipe to head (avoids SIGPIPE under pipefail)
  [[ -n "$line" ]] || return 1
  stripped="${line%%#*}"                 # drop any inline comment
  read -r ref <<<"${stripped#*:}"        # value after `agent_ref:`, whitespace-trimmed
  [[ -n "$ref" ]] || return 1
  printf '%s\n' "$ref"
}

# src_channel_tier <ref>
#   Map a channel ref to its tier and echo it. Accepts either the full
#   `<agent>/<channel>` form (e.g. `dev-lead/v1-stable`) or a bare `<channel>`
#   (e.g. `v1-stable`). The tier is the suffix of a major-scoped
#   `v<MAJOR>-<tier>` channel, or a bare `<tier>` (pre-#1184 legacy form).
#   Recognised tiers: stable | next | ring<N>. Returns non-zero for anything
#   that is not a channel tier at all (`main`, a bare commit SHA, …).
src_channel_tier() {
  local ref="$1" chan tier
  chan="${ref##*/}"                      # channel token (drop any agent/ prefix)
  if [[ "$chan" =~ ^v[0-9]+-(stable|next|ring[0-9]+)$ ]]; then
    tier="${BASH_REMATCH[1]}"
  elif [[ "$chan" =~ ^(stable|next|ring[0-9]+)$ ]]; then
    tier="${BASH_REMATCH[1]}"
  else
    return 1
  fi
  printf '%s\n' "$tier"
}

# src_is_stable_tier <ref>
#   Return 0 iff <ref>'s channel tier is `stable`.
src_is_stable_tier() {
  local ref="$1" tier
  tier="$(src_channel_tier "$ref")" || return 1
  [[ "$tier" = "stable" ]]
}

# src_is_promoted_tier <ref>
#   Exit 0 when <ref> is a PROMOTED channel tier — ring<N> or stable — i.e. code
#   that left `next` only after its promotion gate. This is what SC2 needs: the
#   duty must never run unpromoted (`next`, `@main`, a SHA) code, and a bad
#   promoted tier is rolled back by moving its tag, with no PR to block.
src_is_promoted_tier() {
  local ref="$1" tier
  tier="$(src_channel_tier "$ref")" || return 1
  [[ "$tier" = "stable" ]] || [[ "$tier" =~ ^ring[0-9]+$ ]]
}

# src_assert_self_review_stable <stub_file> [<label>]
#   The end-to-end SC2 guard: parse the stub's channel pin and assert it is a
#   promoted tier (ring<N> or stable; never next, @main or a SHA). On failure emit a message that NAMES SC2 and explains why a
#   `next` pin here is a regression — so a future contributor "fixing the ring
#   drift" is told the constraint rather than deleting the guard.
src_assert_self_review_stable() {
  local file="$1" label="${2:-$1}" ref agent_ref uses_tier agent_tier
  if ! ref="$(src_stub_uses_ref "$file")"; then
    printf '::error::SC2 self-review guard: could not parse a reusable `uses:` channel pin from %s\n' "$file" >&2
    return 1
  fi
  # The `agent_ref` input is the ref dev-lead's own review/merge scripts are
  # checked out from; if it is absent it defaults to `main` in the reusable, so
  # an unset value is itself unpromoted. Fail closed rather than assume promoted.
  if ! agent_ref="$(src_stub_agent_ref "$file")"; then
    printf '::error::SC2 self-review guard: %s declares no `agent_ref` input, so the dev-lead scripts default to `main` (unpromoted). Pin `with: agent_ref: <promoted channel>`.\n' "$label" >&2
    return 1
  fi
  # Both the workflow pin AND the script-checkout ref must be promoted: a promoted
  # `uses:` with a `next` `agent_ref` still runs the duty logic from an unsafe
  # channel, so validating only the `uses:` ref leaves an SC2 bypass open.
  if src_is_promoted_tier "$ref" && src_is_promoted_tier "$agent_ref"; then
    printf 'SC2 self-review guard: %s pins a promoted channel (uses=%s, agent_ref=%s) — OK\n' "$label" "$ref" "$agent_ref"
    return 0
  fi
  uses_tier="$(src_channel_tier "$ref" 2>/dev/null)" || uses_tier="not-a-channel"
  agent_tier="$(src_channel_tier "$agent_ref" 2>/dev/null)" || agent_tier="not-a-channel"
  {
    printf '::error::SC2 REGRESSION: %s pins the self-review/dev duty to an unpromoted channel (uses ref="%s" tier="%s", agent_ref="%s" tier="%s").\n' "$label" "$ref" "$uses_tier" "$agent_ref" "$agent_tier"
    printf 'This repo (.github-private) sits in ring `next`, but its dev-lead review/merge duty MUST pin a PROMOTED channel (ring<N> or stable) on BOTH the\n'
    printf '`uses:` reusable pin AND the `agent_ref` input (the ref its own review/merge scripts are checked out from) so a broken\n'
    printf 'in-development version cannot block the PR that fixes its own breakage. A promoted `uses:` with a `next` `agent_ref` still\n'
    printf 'runs the duty logic from an unsafe channel; a `next`, `@main` or SHA pin here silently re-arms the self-hosting circular dependency\n'
    printf '(Safe Release SC2, epic #495 / story #503).\n'
    printf 'If you are "fixing the ring drift" flagged by pinned-version-report: DO NOT repin to `next` — pinned-version-report is\n'
    printf 'correct from the ring-rollout view and this promoted pin is correct from the SC2 view; the promoted pin is the DELIBERATE SC2\n'
    printf 'exception. See docs/release/versioning.md and docs/initiatives/agentic-release-strategy.md.\n'
  } >&2
  return 1
}
