#!/usr/bin/env bash
# token_report.sh — org-wide Token Cost Observatory report.
#
# Collects per-call token-usage JSONL artifacts (emitted by scripts/lib/token-metrics.sh
# via the pr-review and dev-lead agents) from EVERY non-archived repo in the org, then
# renders a Markdown report aggregated by workflow/tier/model and by repository.
#
# Why org-wide: the agents run as reusable workflows in each *caller* repo, so their
# token-usage artifacts land in those repos — not in .github-private. A single-repo scan
# (the original fleet-monitor inline step) saw only a few percent of real org spend.
#
# Layout:
#   * The render_* functions are PURE — they read a directory of JSONL files and write
#     Markdown to stdout. They are unit-tested in tests/token_report.bats (no network).
#   * main() does the network I/O: repo discovery, artifact download, extraction.
#
# Usage:
#   ORG=petry-projects LOOKBACK_DAYS=7 GH_TOKEN=<pat> bash scripts/token_report.sh > report.md
#
# Environment:
#   ORG            — GitHub org to scan (default: petry-projects)
#   LOOKBACK_DAYS  — rolling window of artifact history to include (default: 7)
#   GH_TOKEN       — PAT with actions:read across the org (artifacts are per-repo)
#   TOKEN_REPORT_OUT — optional path; when set, the report is written there in addition
#                      to stdout.
#   ARTIFACT_OP_TIMEOUT — per-gh-call timeout in seconds (default 60) so one hung/slow
#                      artifact download or listing cannot consume the whole job. 0
#                      disables the wrapper.
#   COLLECT_CONCURRENCY — max concurrent artifact listings/downloads (default 8). The
#                      bulk of collection wall-clock is serial network I/O, so bounded
#                      parallelism is what keeps the run inside the job timeout.
#
# ET formula (GitHub's framework): ET = m × (1.0×I + 0.1×C + 4.0×O)
# The `et` field is precomputed per call by token-metrics.sh; this script only sums it.

set -euo pipefail

ORG="${ORG:-petry-projects}"
LOOKBACK_DAYS="${LOOKBACK_DAYS:-7}"

# ---------------------------------------------------------------------------
# Pricing — load the dated price table so cost + ET share one source of truth.
# ---------------------------------------------------------------------------
if [ -f "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/model-pricing.sh" ]; then
  # shellcheck source=scripts/lib/model-pricing.sh
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/model-pricing.sh"
fi
# Gemini per-key caps (gemini-quota-caps.tsv) for the "Gemini quota" section (#2030).
if [ -f "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/gemini-quota.sh" ]; then
  # shellcheck source=scripts/lib/gemini-quota.sh
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/gemini-quota.sh"
fi

# ---------------------------------------------------------------------------
# Pure rendering helpers (unit-tested)
# ---------------------------------------------------------------------------

# _fmt_int <number>
# Renders an integer with thousands separators (e.g. 1234567 → 1,234,567).
_fmt_int() {
  awk -v n="${1:-0}" 'BEGIN {
    n = int(n + 0.5); s = ""; if (n < 0) { neg = 1; n = -n }
    if (n == 0) s = "0"
    while (n > 0) { r = n % 1000; n = int(n / 1000);
      s = (n > 0) ? sprintf("%03d", r) (s == "" ? "" : "," s) : r (s == "" ? "" : "," s) }
    printf "%s%s", (neg ? "-" : ""), s
  }'
}

# _fmt_usd <dollars>
# Renders a USD amount rounded to 2 decimals (cents), e.g. $1.05. Org standard for
# all surfaced dollar amounts — see AGENTS.md "Cost reporting". Sub-cent values
# round to $0.00; ET (see _fmt_int) remains the fine-grained comparator.
_fmt_usd() {
  awk -v v="${1:-0}" 'BEGIN { printf "$%.2f", v }'
}

# annotate_records <jsonl_dir>
# Joins every record against the dated price table and emits enriched TSV (one row per
# call), pricing each call at the rate in effect on its OWN timestamp. Columns:
#   1 repo  2 workflow  3 tier  4 model  5 input  6 cache  7 output
#   8 cost_usd (-1 when the model price is unknown)  9 et  10 known(1/0)  11 context
#   12 cache_write  13 date (YYYY-MM-DD)  14 duration_ms (empty when null/absent, #1949)
# ET is recomputed here from the table (m = input(model)/input(haiku)), so it can never
# drift from the dollar figure.
annotate_records() {
  local dir="$1"
  local files=("$dir"/*.jsonl)
  [ -e "${files[0]}" ] || return 0   # no JSONL files → no rows
  local _et_baseline_default="claude-haiku-4-5" # model-pin-ok: ET baseline anchor — must stay fixed so historical ET multipliers never drift
  jq -r 'select(type == "object")
    | select((.kind // "token_usage") == "token_usage")
    # Drop empty, model-less records (no model AND zero usage): they are not priced
    # calls at all — counting them inflates the "no price" warning and adds a junk
    # `- / -` cost-driver row (#1009). A real model missing a price still surfaces
    # (known=0 → warns); a real model with an all-zero usage block is still counted.
    | select(
        (((.model // "") | (. == "" or . == "-"))
         and ((.input_tokens // 0) == 0)
         and ((.cache_read_tokens // 0) == 0)
         and ((.cache_creation_tokens // 0) == 0)
         and ((.output_tokens // 0) == 0)) | not
      )
    | [
      (.repo // "unknown"), (.workflow // "unknown"), (.tier // "-"), (.model // "-"),
      (.input_tokens // 0), (.cache_read_tokens // 0), (.output_tokens // 0),
      (.ts // "-"), (.context // ""), (.cache_creation_tokens // 0),
      # Normalise to whole non-negative ms so the numeric filter in the report
      # counts any JSON number (e.g. 12.5, 1e3) rather than silently dropping it.
      (.duration_ms | if type == "number" and . >= 0 then floor else null end)
    ] | @tsv' "${files[@]}" 2>/dev/null \
  | awk -F'\t' -v table="${PRICING_TABLE:-}" -v baseline="${ET_BASELINE_MODEL:-$_et_baseline_default}" '
      function glob2re(g,   re) {
        re = g
        gsub(/[.[\]()^$+{}|\\]/, "\\\\&", re); gsub(/\*/, ".*", re); gsub(/\?/, ".", re)
        return "^" re "$"
      }
      function best_idx(model, d,   i, bs, be, bi) {
        bs = -1; be = ""; bi = 0
        for (i = 1; i <= nr; i++)
          if (model ~ gre[i] && eff[i] <= d)
            if (spec[i] > bs || (spec[i] == bs && eff[i] > be)) { bs = spec[i]; be = eff[i]; bi = i }
        return bi
      }
      BEGIN {
        nr = 0
        if (table != "")
          while ((getline line < table) > 0) {
            if (line ~ /^[[:space:]]*#/) continue
            n = split(line, f, "\t"); if (n < 6) continue
            nr++; gre[nr] = glob2re(f[1]); eff[nr] = f[2]
            tin[nr] = f[3]; tcr[nr] = f[4]; tcw[nr] = f[5]; tout[nr] = f[6]
            lit = f[1]; gsub(/[*?]/, "", lit); spec[nr] = length(lit)
          }
      }
      {
        repo = $1; wf = $2; tier = $3; model = $4
        inp = $5 + 0; ca = $6 + 0; out = $7 + 0; d = substr($8, 1, 10); ctx = $9
        cw = $10 + 0; dur = $11
        mi = best_idx(model, d)
        bi = best_idx(baseline, d)
        bpin = (bi > 0) ? tin[bi] : 0
        if (mi > 0) {
          known = 1
          cost = (inp * tin[mi] + ca * tcr[mi] + cw * tcw[mi] + out * tout[mi]) / 1000000
          m = (bpin > 0) ? tin[mi] / bpin : 1.0
        } else { known = 0; cost = -1; m = 1.0 }
        et = m * (1.0 * inp + 0.1 * ca + 4.0 * out)
        # Enriched cols 1-11 unchanged for downstream; cache_write=12, date=13,
        # duration_ms=14 (empty string when the record carries no duration, #1949).
        printf "%s\t%s\t%s\t%s\t%d\t%d\t%d\t%.6f\t%.4f\t%d\t%s\t%d\t%s\t%s\n",
          repo, wf, tier, model, inp, ca, out, cost, et, known, ctx, cw, d, dur
      }'
}

# top_pr_urls <jsonl_dir> [n]
# Prints the top-N PR URLs by total cost (one per line). Pure: reuses annotate_records.
# Used by main() to resolve PR titles for the cost-per-PR table.
top_pr_urls() {
  local dir="$1" n="${2:-10}"
  annotate_records "$dir" \
    | awk -F'\t' '$11 ~ /\/pull\// { c[$11] += ($10 == 1 ? $8 : 0) }
        END { for (k in c) printf "%.6f\t%s\n", c[k], k }' \
    | sort -t$'\t' -k1,1rn | awk -v n="$n" 'NR <= n { print $2 }'
}

# render_cost_per_day <enriched_file>
# Emits an ASCII stacked-bar chart of daily cost composed by repository: one bar
# per day, length scaled to the priciest day, each segment a top-cost repo (others
# bucketed as "."). Pure: reads only the enriched TSV (date=col13, repo=col1,
# cost=col8, known=col10). No-op when there are no priced, dated rows.
render_cost_per_day() {
  local enriched="$1"
  awk -F'\t' '
    function fmt_usd(v) { return sprintf("$%.2f", v) }
    $10 == 1 && $13 ~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}$/ {
      d = $13; repo = $1
      daycost[d] += $8; cell[d SUBSEP repo] += $8; repotot[repo] += $8
      days[d] = 1; repos[repo] = 1
    }
    END {
      nd = 0; for (d in days) dl[nd++] = d
      for (i = 0; i < nd; i++) for (j = i+1; j < nd; j++) if (dl[j] < dl[i]) { t = dl[i]; dl[i] = dl[j]; dl[j] = t }
      if (nd == 0) exit 0
      nr = 0; for (r in repos) rl[nr++] = r
      for (i = 0; i < nr; i++) for (j = i+1; j < nr; j++) if (repotot[rl[j]] > repotot[rl[i]]) { t = rl[i]; rl[i] = rl[j]; rl[j] = t }
      K = 6; nk = (nr < K ? nr : K)
      for (x = 1; x <= 8; x++) L[x] = substr("ABCDEFGH", x, 1)
      maxday = 0; for (i = 0; i < nd; i++) if (daycost[dl[i]] > maxday) maxday = daycost[dl[i]]
      MAXW = 50

      printf "## Cost per day (stacked by repo)\n\n"
      # Legend: letter → repo (org prefix stripped) with its window total.
      printf "Legend: "
      for (k = 0; k < nk; k++) {
        r = rl[k]; short = r; sub(/^[^/]+\//, "", short)
        printf "`%s` %s (%s)  ", L[k+1], short, fmt_usd(repotot[r])
      }
      if (nr > nk) {
        oc = 0; for (k = nk; k < nr; k++) oc += repotot[rl[k]]
        printf "`.` other (%s)", fmt_usd(oc)
      }
      printf "\n\n```\n"
      for (i = 0; i < nd; i++) {
        d = dl[i]; tot = daycost[d]
        barlen = (maxday > 0) ? int(tot / maxday * MAXW + 0.5) : 0
        line = ""; used = 0
        for (k = 0; k < nk; k++) {
          c = cell[d SUBSEP rl[k]] + 0
          seg = (tot > 0) ? int(c / tot * barlen + 0.5) : 0
          if (used + seg > barlen) seg = barlen - used
          used += seg
          for (s = 0; s < seg; s++) line = line L[k+1]
        }
        oc = 0; for (k = nk; k < nr; k++) oc += cell[d SUBSEP rl[k]] + 0
        if (oc > 0) { seg = barlen - used; for (s = 0; s < seg; s++) line = line "." }
        printf "%s  %8s  %s\n", d, fmt_usd(tot), line
      }
      printf "```\n\n"
    }
  ' "$enriched"
}

# _gq_cell <used> <cap> — "used / cap (pct%)" for one quota window; the cap may be
# `none` (no cap on the window) or `unknown` (not filled yet — shown, never hidden).
_gq_cell() {
  local used="$1" cap="${2:-unknown}"
  case "$cap" in
    none) printf '%s (no cap)' "$(_fmt_int "$used")" ;;
    0)    printf '%s / 0' "$(_fmt_int "$used")" ;;
    *[!0-9]*|'') printf '%s / unknown' "$(_fmt_int "$used")" ;;
    *)    printf '%s / %s (%d%%)' "$(_fmt_int "$used")" "$(_fmt_int "$cap")" $(( used * 100 / cap )) ;;
  esac
}

# render_gemini_quota <jsonl_dir>
# Emits the "Gemini quota (per key index)" section: for every key index × model seen
# in the ledgers, the PEAK requests per minute, tokens per minute and requests per day
# over the lookback against gemini-quota-caps.tsv, plus the cooldowns recorded. Peaks
# are org-wide (every repo's ledger), which is how the shared keys are actually
# consumed. Pure: no network. No-op when no record carries a Gemini key index.
render_gemini_quota() {
  local dir="$1"
  local files=("$dir"/*.jsonl)
  [ -e "${files[0]}" ] || return 0
  # Day buckets follow the configured daily reset (settings rows daily_reset_time /
  # daily_reset_tz in the caps file), not UTC calendar days: bucket = local date of
  # (ts − reset time), so a call just before/after local reset lands in different
  # days. The UTC offset is resolved per distinct UTC hour (handles DST changes).
  local rtime="" rtz="" daylabel="UTC calendar days (daily reset not configured)"
  if declare -F gq_setting >/dev/null 2>&1; then
    rtime="$(gq_setting daily_reset_time)"; rtz="$(gq_setting daily_reset_tz)"
  fi
  local reset_sec=0 offsets='{}' hr off
  if [[ "$rtime" =~ ^([01][0-9]|2[0-3]):([0-5][0-9])$ ]] && [ -n "$rtz" ] && [ "$rtz" != "unknown" ] \
     && TZ="$rtz" date +%z >/dev/null 2>&1 && [ "$(TZ="$rtz" date -d '2026-01-01T00:00:00Z' +%Y 2>/dev/null)" != "" ]; then
    reset_sec=$(( 10#${BASH_REMATCH[1]} * 3600 + 10#${BASH_REMATCH[2]} * 60 ))
    offsets="$(
      jq -r 'select(type == "object" and .engine == "gemini" and .key_index != null and .ts != null)
          | .ts[0:13]' "${files[@]}" 2>/dev/null | sort -u \
      | while IFS= read -r hr; do
          off="$(TZ="$rtz" date -d "${hr}:00:00Z" +%z 2>/dev/null)" || continue
          [[ "$off" =~ ^([+-])([0-9]{2})([0-9]{2})$ ]] || continue
          printf '%s\t%s\n' "$hr" "$(( ${BASH_REMATCH[1]}1 * (10#${BASH_REMATCH[2]} * 3600 + 10#${BASH_REMATCH[3]} * 60) ))"
        done | jq -R -s 'split("\n") | map(select(length > 0) | split("\t") | {(.[0]): (.[1] | tonumber)}) | add // {}'
    )"
    [ -n "$offsets" ] || offsets='{}'
    daylabel="${rtime} ${rtz} reset"
  fi

  local rows
  rows="$(jq -r --argjson off "$offsets" --argjson rs "$reset_sec" '
      select(type == "object" and .engine == "gemini" and .key_index != null)
      | (.ts // "") as $ts
      | (if $ts != "" and ($off[$ts[0:13]] != null)
           then ((try ($ts | fromdateiso8601) catch null) as $e
                 | if $e == null then $ts[0:10]
                   else ($e + $off[$ts[0:13]] - $rs | strftime("%Y-%m-%d")) end)
           else $ts[0:10] end) as $day
      | [ (.kind // "token_usage"), (.key_index | tostring), (.model // "-"), $ts,
          ((.input_tokens // 0) + (.cache_read_tokens // 0) + (.output_tokens // 0)), $day ]
      | @tsv' "${files[@]}" 2>/dev/null \
    | awk -F'\t' '
        $1 == "token_usage" && $4 != "" {
          k = $2 "\t" $3; seen[k] = 1; calls[k]++
          m = k SUBSEP substr($4, 1, 16); d = k SUBSEP $6
          rm[m]++; tm[m] += $5; rd[d]++
          if (rm[m] > prm[k]) prm[k] = rm[m]
          if (tm[m] > ptm[k]) ptm[k] = tm[m]
          if (rd[d] > prd[k]) prd[k] = rd[d]
        }
        $1 == "gemini_key_cooldown" { k = $2 "\t" $3; seen[k] = 1; cd[k]++ }
        END { for (k in seen)
          printf "%s\t%d\t%d\t%d\t%d\t%d\n", k, calls[k], prm[k], ptm[k], prd[k], cd[k] }' \
    | sort -t$'\t' -k1,1n -k2,2)"
  [ -n "$rows" ] || return 0

  printf '## Gemini quota (per key index)\n\n'
  printf 'Peak usage per window over the lookback, metered from the ledger against '
  printf '`scripts/lib/gemini-quota-caps.tsv` (#2030). Minutes are UTC buckets; days use: %s. ' "$daylabel"
  printf '`unknown` = cap not filled yet — the headroom gate treats that key as constrained.\n\n'
  printf '| Key | Model | Tier | Calls | Peak req/min | Peak tok/min | Peak req/day | Cooldowns |\n'
  printf '|---:|---|---|---:|---:|---:|---:|---:|\n'
  local idx model calls prm ptm prd cds caps tier rpm tpm rpd
  while IFS=$'\t' read -r idx model calls prm ptm prd cds; do
    caps=""
    declare -F gq_caps_for >/dev/null 2>&1 && caps="$(gq_caps_for "$idx" "$model")"
    tier="unknown"; rpm="unknown"; tpm="unknown"; rpd="unknown"
    [ -n "$caps" ] && IFS=$'\t' read -r tier rpm tpm rpd <<< "$caps"
    printf '| %s | `%s` | %s | %s | %s | %s | %s | %s |\n' \
      "$idx" "$model" "$tier" "$(_fmt_int "$calls")" \
      "$(_gq_cell "$prm" "$rpm")" "$(_gq_cell "$ptm" "$tpm")" "$(_gq_cell "$prd" "$rpd")" \
      "$(_fmt_int "$cds")"
  done <<< "$rows"
  printf '\n'
}

# render_token_report <jsonl_dir> <lookback_days> <repo_count> <artifact_count> [generated_at]
# Writes the full Markdown report (with USD cost) to stdout. Pure: no network.
# Optional: PR_TITLE_FILE (TSV "url<TAB>title") adds PR titles to the cost-per-PR table.
render_token_report() {
  local dir="$1" lookback="$2" repo_count="$3" artifact_count="$4" generated_at="${5:-}"

  local enriched; enriched="$(mktemp)"
  annotate_records "$dir" > "$enriched"

  local total_calls
  total_calls="$(wc -l < "$enriched" | tr -d ' ')"

  printf '# 📊 Token Cost Observatory — %s-day Report\n\n' "$lookback"
  if [ -n "$generated_at" ]; then
    printf '_Generated %s · org `%s` · %s repos scanned · %s agent runs · %s LLM calls_\n\n' \
      "$generated_at" "$ORG" "$repo_count" "$artifact_count" "$(_fmt_int "$total_calls")"
  else
    printf '_org `%s` · %s repos scanned · %s agent runs · %s LLM calls_\n\n' \
      "$ORG" "$repo_count" "$artifact_count" "$(_fmt_int "$total_calls")"
  fi

  if [ "$total_calls" -eq 0 ]; then
    rm -f "$enriched"
    printf 'No token-usage records found in the last %s days.\n\n' "$lookback"
    render_gemini_quota "$dir"
    return 0
  fi

  # Totals (cost over priced calls; ET over all): et, cost, input, cache_read, cache_write, output, unknown
  local totals total_et total_cost total_in total_cr total_cw total_out unpriced
  totals="$(awk -F'\t' '{ et += $9; inp += $5; cr += $6; cw += $12; out += $7;
      if ($10 == 1) cost += $8; else unk++ }
    END { printf "%.4f\t%.6f\t%d\t%d\t%d\t%d\t%d", et, cost, inp, cr, cw, out, unk }' "$enriched")"
  IFS=$'\t' read -r total_et total_cost total_in total_cr total_cw total_out unpriced <<< "$totals"

  printf 'Estimated USD cost, priced per `scripts/lib/model-pricing.tsv` at each call'"'"'s date '
  printf '(input + cache-read + cache-write + output). '
  printf 'Effective Tokens (ET) `= m × (1.0·input + 0.1·cache + 4.0·output)`, '
  printf 'where `m` = model input price ÷ haiku input price (haiku 1× · sonnet 3× · opus 5×).\n\n'

  printf '## Totals\n\n'
  printf -- '- **Total cost:** %s\n' "$(_fmt_usd "$total_cost")"
  printf -- '- **Total ET:** %s\n' "$(_fmt_int "$total_et")"
  printf -- '- **LLM calls:** %s   ·   **Input tokens:** %s   ·   **Output tokens:** %s\n' \
    "$(_fmt_int "$total_calls")" "$(_fmt_int "$total_in")" "$(_fmt_int "$total_out")"
  printf -- '- **Cache tokens:** %s read · %s write\n' \
    "$(_fmt_int "$total_cr")" "$(_fmt_int "$total_cw")"
  if [ "${unpriced:-0}" -gt 0 ]; then
    printf -- '- ⚠️ **%s call(s) had no price** in the table and are excluded from cost (marked `*`).\n' \
      "$(_fmt_int "$unpriced")"
  fi
  printf '\n'

  printf '## Top cost drivers (workflow / tier / model)\n\n'
  printf '| Workflow | Tier | Model | Calls | Input | Cache | Output | Cost | %% of $ | ET | Mean ms | p50 ms |\n'
  printf '|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|\n'
  # Mean/p50 duration_ms (col 14) are computed only over records that carry a
  # numeric duration; a null/absent duration is excluded, never counted as 0
  # (#1949). A key with no measured durations renders "-" for both latency cells.
  awk -F'\t' '{ k = $2"\t"$3"\t"$4
      calls[k]++; inp[k] += $5; ca[k] += $6; out[k] += $7; et[k] += $9
      if ($10 == 1) cost[k] += $8; else unk[k]++
      if ($14 ~ /^[0-9]+$/) { dsum[k] += $14; dn[k]++; dvals[k] = dvals[k] " " $14 } }
    END { for (k in calls) {
      mean = "-"; p50 = "-"
      if (dn[k] > 0) {
        mean = sprintf("%d", dsum[k] / dn[k] + 0.5)
        n = split(dvals[k], arr, " ")
        for (i = 2; i <= n; i++) { key = arr[i] + 0; j = i - 1;
          while (j >= 1 && arr[j] + 0 > key) { arr[j+1] = arr[j]; j-- } arr[j+1] = key }
        rank = int((n + 1) / 2); if (rank < 1) rank = 1
        p50 = sprintf("%d", arr[rank] + 0)
        delete arr
      }
      printf "%.6f\t%.4f\t%d\t%d\t%d\t%d\t%d\t%s\t%s\t%s\n",
        cost[k], et[k], calls[k], inp[k], ca[k], out[k], unk[k], mean, p50, k } }' "$enriched" \
  | sort -t$'\t' -k1,1rn \
  | while IFS=$'\t' read -r cost et calls input cache output unk mean_ms p50_ms wf tier model; do
      local pct mark=""; [ "$unk" -gt 0 ] && mark="*"
      local mean_disp p50_disp
      [ "$mean_ms" = "-" ] && mean_disp="-" || mean_disp="$(_fmt_int "$mean_ms")"
      [ "$p50_ms" = "-" ] && p50_disp="-" || p50_disp="$(_fmt_int "$p50_ms")"
      pct="$(awk -v c="$cost" -v t="$total_cost" 'BEGIN { printf "%d%%", (t > 0 ? c / t * 100 : 0) }')"
      printf '| `%s` | %s | `%s` | %s | %s | %s | %s | %s%s | %s | %s | %s | %s |\n' \
        "$wf" "$tier" "$model" "$(_fmt_int "$calls")" "$(_fmt_int "$input")" \
        "$(_fmt_int "$cache")" "$(_fmt_int "$output")" "$(_fmt_usd "$cost")" "$mark" "$pct" "$(_fmt_int "$et")" \
        "$mean_disp" "$p50_disp"
    done
  printf '\n'

  # Gemini per-key quota next to the per-model usage above (#2030).
  render_gemini_quota "$dir"

  printf '## By repository\n\n'
  printf '| Repository | Calls | Cost | %% of $ | ET |\n'
  printf '|---|---:|---:|---:|---:|\n'
  awk -F'\t' '{ k = $1
      calls[k]++; et[k] += $9; if ($10 == 1) cost[k] += $8; else unk[k]++ }
    END { for (k in calls)
      printf "%.6f\t%.4f\t%d\t%d\t%s\n", cost[k], et[k], calls[k], unk[k], k }' "$enriched" \
  | sort -t$'\t' -k1,1rn \
  | while IFS=$'\t' read -r cost et calls unk repo; do
      local pct mark=""; [ "$unk" -gt 0 ] && mark="*"
      pct="$(awk -v c="$cost" -v t="$total_cost" 'BEGIN { printf "%d%%", (t > 0 ? c / t * 100 : 0) }')"
      printf '| `%s` | %s | %s%s | %s | %s |\n' \
        "$repo" "$(_fmt_int "$calls")" "$(_fmt_usd "$cost")" "$mark" "$pct" "$(_fmt_int "$et")"
    done
  printf '\n'

  render_cost_per_day "$enriched"

  # Cost-per-PR — each record carries its PR URL in context; surface the priciest PRs.
  # Limit with `awk 'NR<=10'` rather than `head -10`: awk consumes the whole stream, so
  # `sort` never receives SIGPIPE and the command substitution can't fail under pipefail
  # (which would otherwise abort the report — see PR #456 review).
  # When PR_TITLE_FILE (TSV "url<TAB>title") is provided by main(), the first 35 chars
  # of the title are shown; otherwise the Title cell is blank (keeps render network-free).
  local pr_rows
  pr_rows="$(awk -F'\t' '$11 ~ /\/pull\// { k = $11
      calls[k]++; if ($10 == 1) cost[k] += $8 }
    END { for (k in calls) printf "%.6f\t%d\t%s\n", cost[k], calls[k], k }' "$enriched" \
    | sort -t$'\t' -k1,1rn | awk 'NR <= 10')"
  if [ -n "$pr_rows" ]; then
    printf '## Most expensive PRs (top 10)\n\n'
    printf '| PR | Title | Calls | Cost |\n|---|---|---:|---:|\n'
    while IFS=$'\t' read -r cost calls pr; do
      [ -n "$pr" ] || continue
      local title=""
      if [ -n "${PR_TITLE_FILE:-}" ] && [ -f "$PR_TITLE_FILE" ]; then
        # Look up title by URL, strip pipes/newlines, truncate to 35 chars (+…).
        title="$(awk -F'\t' -v u="$pr" '$1 == u {
          t = $2; gsub(/\r/, "", t); gsub(/\|/, "/", t)
          if (length(t) > 35) t = substr(t, 1, 35) "…"
          print t; exit
        }' "$PR_TITLE_FILE")"
      fi
      printf '| %s | %s | %s | %s |\n' "$pr" "$title" "$(_fmt_int "$calls")" "$(_fmt_usd "$cost")"
    done <<< "$pr_rows"
    printf '\n'
  fi

  rm -f "$enriched"
}

# ---------------------------------------------------------------------------
# Network I/O (main)
# ---------------------------------------------------------------------------

# Per-gh-call timeout (seconds) and collection concurrency. See the header.
ARTIFACT_OP_TIMEOUT="${ARTIFACT_OP_TIMEOUT:-60}"
COLLECT_CONCURRENCY="${COLLECT_CONCURRENCY:-8}"

# _gh_timeout <gh-args...>
# Runs `gh "$@"` under a per-call timeout so a single hung/slow request cannot
# stall the whole run (#954). Returns 124 when the call is killed by timeout.
# When ARTIFACT_OP_TIMEOUT is 0 or the `timeout` binary is unavailable, gh runs
# unwrapped. gh is invoked via `bash -c` so an exported shell-function stub (used
# by the unit tests) is still resolved under `timeout`, which only execs binaries.
_gh_timeout() {
  if [ "${ARTIFACT_OP_TIMEOUT:-0}" -gt 0 ] && command -v timeout >/dev/null 2>&1; then
    timeout "${ARTIFACT_OP_TIMEOUT}" bash -c 'gh "$@"' _ "$@"
  else
    gh "$@"
  fi
}

# _extract_zip <zip_file> <dest_dir>
# Extracts a zip using unzip when available, else a python3 fallback (CI runners
# have unzip; the fallback keeps the script runnable in minimal environments).
_extract_zip() {
  local zip="$1" dest="$2"
  if command -v unzip >/dev/null 2>&1; then
    unzip -q -o "$zip" -d "$dest"
  else
    python3 - "$zip" "$dest" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as z:
    z.extractall(sys.argv[2])
PY
  fi
}

# _list_repo_artifacts <repo>
# Lists token-usage artifact IDs in one repo that fall inside the lookback window
# and appends "<repo> <id>" lines to a unique file in COLLECT_LIST_DIR. Each
# worker writes its own file (no shared-fd contention) so the listings can run in
# parallel. Reads CUTOFF / COLLECT_LIST_DIR from the environment. Always exits 0:
# a failed listing degrades to a WARN + a skipped repo, never an aborted run.
_list_repo_artifacts() {
  local repo="$1" arts out
  arts="$(_gh_timeout api "repos/${repo}/actions/artifacts" --paginate 2>/dev/null \
    | jq -r --arg cutoff "$CUTOFF" \
    '.artifacts[] | select(.name | startswith("token-usage-")) | select(.expired == false) | select(.created_at >= $cutoff) | .id | tostring')" || {
    echo "WARN: could not fetch artifacts for ${repo} — skipping (check actions:read permission or timed out)" >&2
    return 0
  }
  [ -n "$arts" ] || return 0
  out="$(mktemp "${COLLECT_LIST_DIR}/list.XXXXXX")" || {
    echo "WARN: failed to create temporary file in ${COLLECT_LIST_DIR} — skipping ${repo}" >&2
    return 0
  }
  local id
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    printf '%s %s\n' "$repo" "$id" >> "$out"
  done <<< "$arts"
}

# _collect_one_artifact <repo> <id>
# Downloads + extracts one artifact and writes its repo-tagged JSONL records into
# COLLECT_JSONL_DIR, touching a marker in COLLECT_MARKER_DIR when ≥1 record is
# written (the caller counts markers for artifact_count). Bounded by _gh_timeout
# so a single hung download is skipped, not waited out. Each worker writes only
# id-scoped paths (artifact IDs are globally unique on GitHub) so parallel workers
# never collide. Reads COLLECT_* from the environment. Always exits 0.
_collect_one_artifact() {
  local repo="$1" id="$2"
  local zip="$COLLECT_WORKDIR/a-$id.zip" ex="$COLLECT_WORKDIR/x-$id"
  mkdir -p "$ex"
  if ! _gh_timeout api "repos/${repo}/actions/artifacts/${id}/zip" > "$zip" 2>/dev/null; then
    echo "WARN: artifact ${id} from ${repo} — download failed or timed out; skipping (report may be incomplete)" >&2
    rm -rf "$zip" "$ex"
    return 0
  fi
  if ! _extract_zip "$zip" "$ex" 2>/dev/null; then
    echo "WARN: artifact ${id} from ${repo} — extraction failed; skipping (report may be incomplete)" >&2
    rm -rf "$zip" "$ex"
    return 0
  fi

  local found=false f dest
  while IFS= read -r f; do
    # Tag each record with its source repo for the by-repo rollup.
    dest="$COLLECT_JSONL_DIR/${id}-$(basename "$f")"
    if jq -c --arg repo "$repo" 'select(type=="object") | . + {repo: $repo}' \
        "$f" > "$dest" 2>/dev/null; then
      found=true
    else
      # jq creates the destination before it can fail on malformed input;
      # remove it so annotate_records never sees a corrupt *.jsonl file.
      rm -f "$dest" 2>/dev/null || true
    fi
  done < <(find "$ex" -type f -name '*.jsonl' -print)
  [ "$found" = true ] && : > "$COLLECT_MARKER_DIR/$id"

  rm -rf "$zip" "$ex"
  return 0
}

# collect_org_jsonl <jsonl_dir>  (stdout: "<repo_count> <artifact_count>")
# Discovers non-archived repos, then — in two bounded-parallel passes — lists each
# repo's in-window token-usage artifacts and downloads/extracts them, tagging every
# record with its source repo. Per-call timeouts (_gh_timeout) bound any single
# hung request; COLLECT_CONCURRENCY bounds the fan-out (#954).
collect_org_jsonl() {
  local jsonl_dir="$1"
  mkdir -p "$jsonl_dir"

  local repos_raw
  if ! repos_raw="$(_gh_timeout api "orgs/${ORG}/repos?per_page=100&type=all" --paginate \
    --jq '.[] | select(.archived == false) | .full_name')"; then
    echo "ERROR: org repo discovery for '${ORG}' failed — verify GH_TOKEN has org read access." >&2
    return 1
  fi
  [ -n "$repos_raw" ] || { echo "0 0"; return 0; }

  local repo_count
  repo_count="$(printf '%s\n' "$repos_raw" | awk 'NF{c++} END{print c+0}')"

  # Shared state for the parallel workers, all under one workdir for cleanup.
  local workdir; workdir="$(mktemp -d)" || {
    echo "ERROR: failed to create temporary directory" >&2
    return 1
  }
  # shellcheck disable=SC2064
  trap "rm -rf '$workdir'" RETURN
  CUTOFF="$(date -u -d "${LOOKBACK_DAYS} days ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -v-"${LOOKBACK_DAYS}"d +%Y-%m-%dT%H:%M:%SZ)"
  # ARTIFACT_OP_TIMEOUT is read by _gh_timeout *inside* the xargs workers, so it
  # must be exported or the per-download timeout silently disables in the fan-out.
  export ARTIFACT_OP_TIMEOUT
  export CUTOFF COLLECT_JSONL_DIR="$jsonl_dir" COLLECT_WORKDIR="$workdir"
  export COLLECT_LIST_DIR="$workdir/list" COLLECT_MARKER_DIR="$workdir/markers"
  mkdir -p "$COLLECT_LIST_DIR" "$COLLECT_MARKER_DIR"
  export -f _list_repo_artifacts _collect_one_artifact _gh_timeout _extract_zip

  # Pass 1 — list artifacts across all repos in parallel (one worker per repo).
  # pipefail in the worker so a failed `gh | jq` listing surfaces as the WARN path
  # rather than being masked by jq's success on empty input.
  printf '%s\n' "$repos_raw" \
    | xargs -P "$COLLECT_CONCURRENCY" -I {} \
        bash -c 'set -o pipefail; _list_repo_artifacts "$1"' _ {} \
    || true

  # Pass 2 — download + extract each "<repo> <id>" pair in parallel.
  local worklist="$workdir/worklist"
  find "$COLLECT_LIST_DIR" -type f -exec cat {} + > "$worklist" 2>/dev/null || true
  if [ -s "$worklist" ]; then
    xargs -P "$COLLECT_CONCURRENCY" -n 2 \
      bash -c '_collect_one_artifact "$1" "$2"' _ < "$worklist" \
      || true
  fi

  local artifact_count
  artifact_count="$(find "$COLLECT_MARKER_DIR" -type f | wc -l | tr -d ' ')"

  echo "${repo_count} ${artifact_count}"
}

main() {
  local jsonl_dir counts repo_count artifact_count generated_at report
  jsonl_dir="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$jsonl_dir'" EXIT

  echo "Collecting token-usage artifacts across ${ORG} (last ${LOOKBACK_DAYS} days)..." >&2
  counts="$(collect_org_jsonl "$jsonl_dir")"
  repo_count="${counts%% *}"
  artifact_count="${counts##* }"
  generated_at="$(date -u +%Y-%m-%d 2>/dev/null || echo '')"

  # Resolve PR titles for the priciest PRs so render can show them (network step;
  # render itself stays pure and just reads PR_TITLE_FILE).
  local titles_file purl ptitle
  titles_file="$jsonl_dir/pr_titles.tsv"
  if command -v gh >/dev/null 2>&1; then
    while IFS= read -r purl; do
      [ -n "$purl" ] || continue
      ptitle="$(gh pr view "$purl" --json title -q '.title' 2>/dev/null || true)"
      [ -n "$ptitle" ] && printf '%s\t%s\n' "$purl" "$ptitle" >> "$titles_file"
    done < <(top_pr_urls "$jsonl_dir" 10)
  fi
  export PR_TITLE_FILE="$titles_file"

  report="$(render_token_report "$jsonl_dir" "$LOOKBACK_DAYS" \
            "$repo_count" "$artifact_count" "$generated_at")"

  printf '%s\n' "$report"
  if [ -n "${TOKEN_REPORT_OUT:-}" ]; then
    printf '%s\n' "$report" > "$TOKEN_REPORT_OUT"
  fi
}

# Only run main when executed directly (not when sourced by tests).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
