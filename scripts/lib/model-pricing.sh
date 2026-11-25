#!/usr/bin/env bash
# model-pricing.sh — effective-dated LLM price lookup + cost/ET derivation.
#
# Single source of truth for prices is model-pricing.tsv (same directory). This
# library is the ONLY place token counts are turned into dollars or ET multipliers,
# so every surface that shows cost stays consistent.
#
# Functions (all pure — deterministic, no network):
#   price_for <model> [iso_date]            → "input cache_read output" USD/MTok, or "" if unknown
#   cost_usd  <model> <in> <cache> <out> [iso_date]  → USD cost (6dp), or "" if price unknown
#   et_multiplier_for <model> [iso_date]    → ET multiplier m = input(model)/input(baseline), default 1.0
#
# Pricing is effective-dated: a record is priced at the rate in effect on its own
# date (see model-pricing.tsv for the selection rule). iso_date defaults to today.
#
# Environment:
#   PRICING_TABLE       — path to the TSV (default: alongside this script)
#   ET_BASELINE_MODEL   — model whose input price is ET's "1.0" (default claude-haiku-4-5) # model-pin-ok: ET baseline anchor — must stay fixed so historical ET multipliers never drift

# Resolve the table path once, relative to this file (works when sourced from anywhere).
if [[ -z "${PRICING_TABLE:-}" ]]; then
  PRICING_TABLE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/model-pricing.tsv"
fi
: "${ET_BASELINE_MODEL:=claude-haiku-4-5}" # model-pin-ok: ET baseline anchor — must stay fixed so historical ET multipliers never drift

# price_for <model> [iso_date]
# Echoes "input cache_read cache_write output" (USD/MTok) for the rate in effect at
# iso_date, selecting the most-specific matching glob (ties → latest effective_from).
# Echoes nothing when no row matches (caller treats as unknown price).
price_for() {
  local model="$1" date="${2:-}"
  [[ -n "$date" ]] || date="$(date -u +%Y-%m-%d 2>/dev/null || echo '9999-12-31')"
  [[ -f "$PRICING_TABLE" ]] || return 0

  awk -F'\t' -v model="$model" -v d="$date" '
    function glob2re(g,   re) {
      re = g
      gsub(/[.[\]()^$+{}|\\]/, "\\\\&", re)   # escape regex metachars
      gsub(/\*/, ".*", re)                      # glob * → regex .*
      gsub(/\?/, ".",  re)                      # glob ? → regex .
      return "^" re "$"
    }
    /^[[:space:]]*#/ { next }                    # comments
    NF < 6          { next }                     # blanks / malformed
    {
      glob = $1; eff = $2
      if (model ~ glob2re(glob) && eff <= d) {
        lit = glob; gsub(/[*?]/, "", lit); spec = length(lit)
        if (spec > best_spec || (spec == best_spec && eff > best_eff)) {
          best_spec = spec; best_eff = eff; bi = $3; bc = $4; bw = $5; bo = $6; found = 1
        }
      }
    }
    END { if (found) printf "%s %s %s %s", bi, bc, bw, bo }
  ' "$PRICING_TABLE"
}

# cost_usd <model> <input> <cache_read> <output> [iso_date] [cache_write]
# Echoes the USD cost (6 decimals) using the date-accurate rate. Echoes nothing when
# the model's price is unknown — callers MUST surface that (never treat as $0).
# cache_write defaults to 0 so existing 4-arg callers are unaffected.
cost_usd() {
  local model="$1" in="${2:-0}" cr="${3:-0}" out="${4:-0}" date="${5:-}" cw="${6:-0}"
  local p; p="$(price_for "$model" "$date")"
  [[ -n "$p" ]] || return 0
  local pin pcr pcw pout; read -r pin pcr pcw pout <<< "$p"
  awk -v i="$in" -v c="$cr" -v w="$cw" -v o="$out" \
      -v pin="$pin" -v pcr="$pcr" -v pcw="$pcw" -v pout="$pout" \
    'BEGIN { printf "%.6f", (i * pin + c * pcr + w * pcw + o * pout) / 1000000 }'
}

# et_multiplier_for <model> [iso_date]
# Returns m = input_price(model, date) / input_price(baseline, date). Date-accurate,
# so ET can never drift from the price table. Falls back to 1.0 when either price is
# unknown (safe default — never fails).
et_multiplier_for() {
  local model="$1" date="${2:-}"
  local mp bp
  mp="$(price_for "$model" "$date")"
  bp="$(price_for "$ET_BASELINE_MODEL" "$date")"
  if [[ -z "$mp" ]] || [[ -z "$bp" ]]; then echo "1.0"; return 0; fi
  # %.1f keeps the canonical "5.0"/"0.5" form used elsewhere; all current multipliers
  # (0.5, 1, 2, 3, 5) are exact at one decimal.
  awk -v m="${mp%% *}" -v b="${bp%% *}" \
    'BEGIN { printf "%.1f", (b > 0 ? m / b : 1.0) }'
}
