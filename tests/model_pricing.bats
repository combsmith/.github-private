#!/usr/bin/env bats
# Tests for scripts/lib/model-pricing.sh — effective-dated price lookup, cost, ET.
# Run locally: bats tests/model_pricing.bats

setup() {
  # shellcheck source=scripts/lib/model-pricing.sh
  source "${BATS_TEST_DIRNAME}/../scripts/lib/model-pricing.sh"
}

# ---------------------------------------------------------------------------
# price_for — against the production table
# ---------------------------------------------------------------------------

# Output is "input cache_read cache_write output".
@test "price_for: opus 4.7 at a 2026 date → \$5 / \$0.50 / \$6.25 / \$25" {
  run price_for "claude-opus-4-7" "2026-06-07"
  [ "$output" = "5.00 0.50 6.25 25.00" ]
}

@test "price_for: sonnet 4.6 → \$3 / \$0.30 / \$3.75 / \$15" {
  run price_for "claude-sonnet-4-6" "2026-06-07"
  [ "$output" = "3.00 0.30 3.75 15.00" ]
}

@test "price_for: sonnet 5 intro window → \$2 / \$0.20 / \$2.50 / \$10" {
  run price_for "claude-sonnet-5-20261231" "2026-07-15"
  [ "$output" = "2.00 0.20 2.50 10.00" ]
}

# The 2026-09-01 increase to $3/$15 was cancelled (pricing page footnote 3), so the
# $2/$10 launch rate is now the standard price — the boundary row is corrected to $2.
@test "price_for: sonnet 5 at cancelled-increase boundary (2026-09-01) → still \$2 / \$0.20 / \$2.50 / \$10" {
  run price_for "claude-sonnet-5-20261231" "2026-09-01"
  [ "$output" = "2.00 0.20 2.50 10.00" ]
}

@test "price_for: sonnet 5 after 2026-09-01 → still \$2 / \$0.20 / \$2.50 / \$10 (increase cancelled)" {
  run price_for "claude-sonnet-5-20261231" "2026-09-02"
  [ "$output" = "2.00 0.20 2.50 10.00" ]
}

# The bare alias `claude-sonnet-5` is the real model id (#1957); the
# `claude-sonnet-5-*` glob does not match it, so it has its own rows.
@test "price_for: bare claude-sonnet-5 is priced (intro window) — #1957" {
  run price_for "claude-sonnet-5" "2026-07-15"
  [ "$output" = "2.00 0.20 2.50 10.00" ]
}

@test "price_for: bare claude-sonnet-5 is priced (after 2026-09-01) — #1957" {
  run price_for "claude-sonnet-5" "2026-09-27"
  [ "$output" = "2.00 0.20 2.50 10.00" ]
}

# Sonnet 5.5 (#1978): the `claude-sonnet-5-5*` glob (17 literal chars) is more
# specific than `claude-sonnet-5-*` (16), so a claude-sonnet-5-5 record resolves
# to its own row — never leaking into the general sonnet-5 rate. Prices verified
# against https://platform.claude.com/docs/en/about-claude/pricing (2026-09-28):
# input $2 / cache-read $0.20 / 5m cache-write $2.50 / output $10.
@test "price_for: sonnet 5.5 pinned at effective_from (2026-09-28) → \$2 / \$0.20 / \$2.50 / \$10 — #1978" {
  run price_for "claude-sonnet-5-5" "2026-09-28"
  [ "$output" = "2.00 0.20 2.50 10.00" ]
}

@test "price_for: sonnet 5.5 beats the claude-sonnet-5-* glob after 2026-09-01 — #1978" {
  run price_for "claude-sonnet-5-5" "2026-10-01"
  [ "$output" = "2.00 0.20 2.50 10.00" ]
}

# The bare `claude-sonnet-5` id keeps its own rows and is unaffected by the new
# 5-5 row — proving the two ids are priced independently. Both now resolve to the
# $2/$10 standard rate (the sonnet-5 September increase was cancelled).
@test "price_for: bare claude-sonnet-5 unaffected by the 5-5 row — #1978" {
  run price_for "claude-sonnet-5" "2026-10-01"
  [ "$output" = "2.00 0.20 2.50 10.00" ]
}

@test "price_for: more-specific glob wins (opus-4-1 legacy = \$15, not \$5)" {
  run price_for "claude-opus-4-1-20250805" "2026-06-07"
  [ "$output" = "15.00 1.50 18.75 75.00" ]
}

# Boundary lock for the date-versioned opus-5-5 row: the rate applies exactly at its
# effective_from (2026-09-22) and there is no retroactive guess for calls before it.
# Sampling the exact boundary (not a day after) is what pins effective_from against drift.
@test "price_for: opus 5.5 pinned at effective_from (2026-09-22) → \$4 / \$0.20 / \$5 / \$20" {
  run price_for "claude-opus-5-5" "2026-09-22"
  [ "$output" = "4.00 0.20 5.00 20.00" ]
}

@test "price_for: opus 5.5 before effective_from (2026-09-21) → empty (no retroactive guess)" {
  run price_for "claude-opus-5-5" "2026-09-21"
  [ -z "$output" ]
}

# Fable 5.2 has its own row: the claude-fable-5-2* glob beats claude-fable-5*, so it
# takes $8/$40 (cache read 2.5% of input), and bare claude-fable-5 keeps its rate.
@test "price_for: bare claude-fable-5 before 5.2 effective_from (2026-11-08) → \$10 / \$1.00 / \$12.50 / \$50.00" {
  run price_for "claude-fable-5" "2026-11-08"
  [ "$output" = "10.00 1.00 12.50 50.00" ]
}

@test "price_for: fable 5.2 pinned at effective_from (2026-11-09) → \$8 / \$0.20 / \$10 / \$40" {
  run price_for "claude-fable-5-2" "2026-11-09"
  [ "$output" = "8.00 0.20 10.00 40.00" ]
}

@test "price_for: bare claude-fable-5 unaffected by the 5-2 row" {
  run price_for "claude-fable-5" "2026-11-10"
  [ "$output" = "10.00 1.00 12.50 50.00" ]
}

@test "price_for: unknown model → empty" {
  run price_for "mystery-model-v9" "2026-06-07"
  [ -z "$output" ]
}

# gemini-3.5-flash: mis-priced 2026-06-11 row corrected by an appended 2026-07-14
# row (issue #1205). Historical lookups stay on the old rate; post-correction
# lookups pick up the verified Google rate (input 1.50 / cache_read 0.15 / output 9.00).
@test "price_for: gemini-3.5-flash historical (pre-correction) → \$0.30 / \$0.03 / \$0.30 / \$1.20" {
  run price_for "gemini-3.5-flash" "2026-07-01"
  [ "$output" = "0.30 0.03 0.30 1.20" ]
}

@test "price_for: gemini-3.5-flash corrected (post-correction) → \$1.50 / \$0.15 / \$1.50 / \$9.00" {
  run price_for "gemini-3.5-flash" "2026-07-14"
  [ "$output" = "1.50 0.15 1.50 9.00" ]
}

# ---------------------------------------------------------------------------
# Effective-date selection (dedicated fixture table with two dated rows)
# ---------------------------------------------------------------------------

@test "price_for: selects the rate in effect on the record's date" {
  PRICING_TABLE="$(mktemp)"
  {
    printf '# glob\teff\tin\tcr\tcw\tout\n'
    printf 'test-model*\t2025-01-01\t10.00\t1.00\t12.50\t40.00\n'
    printf 'test-model*\t2026-03-01\t8.00\t0.80\t10.00\t32.00\n'
  } > "$PRICING_TABLE"
  before="$(price_for "test-model-x" "2026-02-15")"   # before the price drop
  after="$(price_for  "test-model-x" "2026-03-02")"   # after the price drop
  rm -f "$PRICING_TABLE"
  [ "$before" = "10.00 1.00 12.50 40.00" ]
  [ "$after"  = "8.00 0.80 10.00 32.00" ]
}

# #1978 AC-1: a claude-sonnet-5-5 record resolves to the claude-sonnet-5-5* row,
# not claude-sonnet-5-*. The production rows share one rate, so only a fixture
# with distinct rates can tell the two rows apart.
@test "price_for: claude-sonnet-5-5* beats claude-sonnet-5-* (distinct fixture rates) — #1978" {
  PRICING_TABLE="$(mktemp)"
  {
    printf 'claude-sonnet-5-*\t2026-06-30\t1.00\t0.10\t1.25\t5.00\n'
    printf 'claude-sonnet-5-5*\t2026-09-28\t7.00\t0.70\t8.75\t35.00\n'
    printf 'claude-sonnet-5\t2026-06-30\t3.00\t0.30\t3.75\t15.00\n'
  } > "$PRICING_TABLE"
  five_five="$(price_for "claude-sonnet-5-5" "2026-10-01")"
  dated_five="$(price_for "claude-sonnet-5-20261231" "2026-10-01")"
  bare_five="$(price_for "claude-sonnet-5" "2026-10-01")"
  rm -f "$PRICING_TABLE"
  [ "$five_five"  = "7.00 0.70 8.75 35.00" ]
  [ "$dated_five" = "1.00 0.10 1.25 5.00" ]
  [ "$bare_five"  = "3.00 0.30 3.75 15.00" ]
}

@test "price_for: date before the earliest effective_from → empty (no retroactive guess)" {
  PRICING_TABLE="$(mktemp)"
  printf 'test-model*\t2026-03-01\t8.00\t0.80\t10.00\t32.00\n' > "$PRICING_TABLE"
  run price_for "test-model-x" "2025-01-01"
  rm -f "$PRICING_TABLE"
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# cost_usd
# ---------------------------------------------------------------------------

@test "cost_usd: opus 21952/0/14665 ≈ \$0.476385 (no cache)" {
  run cost_usd "claude-opus-4-7" 21952 0 14665 "2026-06-07"
  [ "$output" = "0.476385" ]
}

@test "cost_usd: includes cache-read and cache-write terms" {
  # opus: input 0, cache_read 1000 (@\$0.50), output 0, cache_write 1000 (@\$6.25)
  # = (1000*0.5 + 1000*6.25)/1e6 = 6750/1e6 = 0.006750
  run cost_usd "claude-opus-4-7" 0 1000 0 "2026-06-07" 1000
  [ "$output" = "0.006750" ]
}

@test "cost_usd: unknown model → empty (never silently \$0)" {
  run cost_usd "mystery-model-v9" 1000 0 500 "2026-06-07"
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# et_multiplier_for — derived from the same table (fixes stale opus=15)
# ---------------------------------------------------------------------------

@test "et_multiplier_for: haiku baseline = 1.0" {
  run et_multiplier_for "claude-haiku-4-5-20251001" "2026-06-07"
  [ "$output" = "1.0" ]
}

@test "et_multiplier_for: sonnet = 3.0" {
  run et_multiplier_for "claude-sonnet-4-6" "2026-06-07"
  [ "$output" = "3.0" ]
}

@test "et_multiplier_for: opus 4.7 = 5.0 (was hardcoded 15)" {
  run et_multiplier_for "claude-opus-4-7" "2026-06-07"
  [ "$output" = "5.0" ]
}

@test "et_multiplier_for: unknown model → safe default 1.0" {
  run et_multiplier_for "mystery-model-v9" "2026-06-07"
  [ "$output" = "1.0" ]
}
