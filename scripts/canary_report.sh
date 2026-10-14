#!/usr/bin/env bash
# canary_report.sh — deep-tier model canary go/no-go report (#1951, epic #1895).
#
# Turns a directory of pr-review token-usage JSONL artifacts into a mechanical
# PASS / FAIL / INSUFFICIENT table comparing a CANDIDATE model against an
# INCUMBENT model on the three bars #1899's go/no-go depends on:
#
#   • cost per invocation   — candidate must be ≥ 20% lower
#   • cache-read cost        — candidate must be ≥ 50% lower
#   • latency (duration_ms)  — candidate must be ≥ 20% better
#
# The overall verdict is PASS only when all three PASS. Exit codes encode it so a
# workflow can gate on it: 0 = PASS, 1 = FAIL, 2 = INSUFFICIENT. Missing data
# never reads as PASS — a metric with too small a sample (or no latency signal)
# is INSUFFICIENT, not PASS. An OPERATIONAL error (corrupt/structurally-invalid
# evidence, an unwritable temp/snapshot dir, a bad CLI value) exits >2 (3) — a code
# distinct from every verdict, so a workflow never mistakes a failed run for a
# valid INSUFFICIENT and leave the summary green-but-empty (#1953).
#
# Layout mirrors token_report.sh:
#   * canary_annotate / render_canary_report are PURE — they read a directory of
#     JSONL files and write Markdown to stdout (unit-tested in
#     tests/canary_report.bats, no network).
#   * main() does the network I/O: it downloads this repo's token-usage-*
#     artifacts over a window, REUSING token_report.sh's collection helpers
#     (_gh_timeout / _extract_zip / _collect_one_artifact), or reads a local
#     directory (--dir) — so it can also score a model-ab-tokens-* snapshot.
#
# Pricing is delegated to price_for <model> <record-date> from
# scripts/lib/model-pricing.sh (the same effective-dated model-pricing.tsv source
# token_report.sh uses). Records whose model has no price on their date are
# COUNTED and REPORTED as unpriced — never silently dropped, never treated as $0.
#
# ── Sample selection ──────────────────────────────────────────────────────────
#   Candidate (canary): distinct pr-review PRs whose deep-tier record carries
#   model=<candidate-model>. First --candidate-max-prs (10) distinct PRs in time
#   order at/after --since (the canary window start). A deep-tier call that fell
#   back to another model is listed separately and counts toward neither arm.
#
#   Incumbent (baseline): tier=deep, model=<incumbent-model> records from the
#   baseline window. By default that is --baseline-days (14) ending at --since;
#   --baseline-since / --baseline-until override it explicitly.
#
#   --candidate and --incumbent are REQUIRED (also CANARY_CANDIDATE /
#   CANARY_INCUMBENT): no model ID is hard-coded in this script. The pass/fail bars
#   and sample floors are flags (--cost-bar, --cache-bar, --latency-bar, --min-prs,
#   --min-invocations; flag wins over the CANARY_* env var) with the defaults above.
#
#   Latency is only scored on records inside these windows (candidate at/after
#   --since; incumbent inside the baseline window), so records with no
#   duration_ms surface as INSUFFICIENT latency rather than a false PASS.
#
# ── Baseline expiry — snapshot both arms before the baseline is gone ──────────
#   token-usage artifacts are retained 30 days (pr-review.yml upload step). Snapshot
#   a directory holding BOTH arms BEFORE the incumbent baseline expires:
#
#     GH_TOKEN=<pat> bash scripts/canary_report.sh \
#       --collect-only --dir ./canary-snapshot --since <canary-start> \
#       --baseline-days 14 --candidate <candidate-model> --incumbent <incumbent-model>
#
#   --collect-only has NO artifact upper bound, so one collection from the baseline
#   start captures the expiring incumbent baseline AND every candidate record uploaded
#   since — both arms land in one directory (a snapshot bounded at the cut would hold
#   zero candidate records and could only score INSUFFICIENT, #1953). Re-run the same
#   command any time to TOP UP the snapshot as more canary PRs accrue (collect-only
#   appends into --dir; it never overwrites). Score offline with --dir ./canary-snapshot;
#   the window cutoffs are applied at scoring time on each record's timestamp, so the
#   snapshot may safely hold records on either side of them.
#
# ── Controlled comparison (model-ab, identical inputs, #1950) ─────────────────
#   Point --model-ab-dir at a model-ab-tokens-* artifact directory to render a
#   SEPARATE section that scores both arms from that directory (both ran on
#   identical inputs). It is reported beside — never merged with — the real-PR
#   section.
#
# COST CAP: read-only over existing artifacts. It makes NO model calls.
#
# Usage:
#   GH_TOKEN=<pat> bash scripts/canary_report.sh --candidate <candidate-model> \
#     --incumbent <incumbent-model> --since <canary-start-iso>
#   bash scripts/canary_report.sh --candidate <candidate-model> \
#     --incumbent <incumbent-model> --dir ./canary-snapshot
#   bash scripts/canary_report.sh --candidate <candidate-model> \
#     --incumbent <incumbent-model> --model-ab-dir ./model-ab-tokens   # controlled only

set -euo pipefail

# Reuse token_report.sh's pricing (price_for), formatters (_fmt_usd/_fmt_int) and
# artifact-collection helpers (_gh_timeout / _extract_zip / _collect_one_artifact).
# Sourcing does not run its main() (guarded by BASH_SOURCE == $0 there).
_CANARY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/token_report.sh
source "${_CANARY_DIR}/token_report.sh"

# ---------------------------------------------------------------------------
# Pure helpers
# ---------------------------------------------------------------------------

# _fmt_pct <fraction>  → "NN%" (fraction 0.225 → "23%"). Negative preserved
# (e.g. -0.2 → "-20%") so a regression is never rendered as a reduction.
# Uses proper rounding with int(x + (x >= 0 ? 0.5 : -0.5)), then ensures
# result is never -0 (which would print as "-0%" and be misleading).
_fmt_pct() {
  awk -v v="${1:-0}" 'BEGIN { x = v * 100; rounded = int(x + (x >= 0 ? 0.5 : -0.5)); if (rounded == -0) rounded = 0; printf "%d%%", rounded }'
}

# _fmt_ms <ms>  → integer milliseconds, or "n/a" for the -1 sentinel.
_fmt_ms() {
  awk -v v="${1:-0}" 'BEGIN { if (v < 0) printf "n/a"; else printf "%d ms", int(v + 0.5) }'
}

# _norm_iso <iso8601>  → the same instant as a canonical UTC seconds-precision
# timestamp (…THH:MM:SSZ), so a window bound compares correctly (lexically) against
# the seconds-precision UTC record timestamps token capture emits. A minute-precision
# bound is padded to seconds; a bare (Zless) UTC bound gets its trailing Z. Without
# canonicalization "…14:07:30Z" sorts BEFORE a "…14:07Z" bound (':' < 'Z'),
# excluding records created in the cutoff minute (#1953). Empty stays empty.
#
# Bounds we CANNOT compare safely against UTC "…Z" timestamps are REJECTED (return
# 1) rather than silently mis-windowed: a non-UTC offset (…+01:00 / …-05:00) or a
# fractional-second form (…:00.123Z) is lexically incomparable with "…SSZ" — e.g.
# 15:07:00+01:00 is the same instant as 14:07:00Z but sorts as a different string,
# so it would drop or admit the wrong hour of records (#1953). Callers must convert
# such inputs to UTC (…Z) first; we fail closed rather than score the wrong window.
_norm_iso() {
  local t="${1-}" n
  case "$t" in
    "")                                     return 0 ;;
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z)    n="$t" ;;
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]Z)               n="${t%Z}:00Z" ;;
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9])     n="${t}Z" ;;
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9])                n="${t}:00Z" ;;
    *)  echo "ERROR: unsupported timestamp '${t}': use canonical UTC ISO-8601 (YYYY-MM-DDTHH:MM[:SS]Z). Numeric offsets and fractional seconds are not lexically comparable with UTC record timestamps and are rejected." >&2
        return 1 ;;
  esac
  # The patterns above only check shape; reject impossible calendar/clock values
  # (month 13, Feb 30, 25:99, second 60) by round-tripping through date(1) — a
  # normalizing parser changes an invalid value, so any mismatch means invalid.
  local rt
  # GNU date uses -d; BSD/macOS date needs -j -f (same fallback as the other scripts).
  if ! rt="$(date -u -d "$n" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
      || date -u -j -f %Y-%m-%dT%H:%M:%SZ "$n" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" \
      || [ "$rt" != "$n" ]; then
    echo "ERROR: invalid UTC timestamp '${t}': not a real calendar date/time." >&2
    return 1
  fi
  printf '%s' "$n"
}

# _combine_verdict <rc1> <rc2>  → the worse go/no-go exit code of the two report
# sections. An OPERATIONAL error (>2) from either section dominates and is passed
# through unchanged — it must never be collapsed into a verdict (a section that
# failed to render is not a PASS). Otherwise any FAIL (1) wins over any
# INSUFFICIENT (2), which wins over PASS (0). So a controlled-comparison FAIL — or
# a controlled-comparison operational error — is never masked by a real-PR PASS
# (#1953).
_combine_verdict() {
  if [ "$1" -gt 2 ]; then printf '%s' "$1"; return; fi
  if [ "$2" -gt 2 ]; then printf '%s' "$2"; return; fi
  if [ "$1" = 1 ] || [ "$2" = 1 ]; then printf 1
  elif [ "$1" = 2 ] || [ "$2" = 2 ]; then printf 2
  else printf 0; fi
}

# _fmt_usd_or_na <dollars>  → the org 2-decimal USD formatter (_fmt_usd), or "n/a"
# for the -1 sentinel. Surfaced USD must go through the shared cents formatter per
# AGENTS.md "Cost reporting"; the reduction % column and the USD/1M-token row are
# the fine-grained comparators when cent precision is too coarse.
_fmt_usd_or_na() {
  local v="${1:-0}"
  if awk -v v="$v" 'BEGIN { exit !(v < 0) }'; then
    printf 'n/a'
  else
    _fmt_usd "$v"
  fi
}

# canary_annotate <jsonl_dir>
# One enriched TSV row per token_usage record, priced via price_for at the
# record's own date. Columns:
#   1 ts  2 workflow  3 tier  4 model  5 input  6 cache_read  7 cache_write
#   8 output  9 context  10 duration_ms (empty when null)
#   11 cost_usd (-1 when unpriced)  12 cache_read_cost_usd (-1 when unpriced)
#   13 known (1 priced / 0 unpriced)
canary_annotate() {
  local dir="$1"
  local files=("$dir"/*.jsonl)
  [ -e "${files[0]}" ] || return 0   # no JSONL files → no rows

  # Reject structurally invalid evidence before scoring (#1953). A structurally
  # invalid record — a non-object (array/scalar), a token_usage object missing a
  # scoring-critical field, or an unrecognized record kind — must ABORT annotation
  # (render_canary_report then fails closed with the operational exit code) rather
  # than be silently discarded or coerced to placeholder labels / zero counts, which
  # could let the surviving rows score a bogus PASS on partial evidence. Recognized
  # non-token audit kinds (finding_verification, lsp_cold_start, gemini_key_cooldown,
  # gemini_attempt, gemini_rejection_sample — see scripts/lib/token-metrics.sh and
  # scripts/lib/gemini-quota.sh; keep in sync) are legitimately skipped, not scored.
  # duration_ms stays optional: real emit_token_record output carries none yet, so a
  # missing/null duration is "", not invalid.
  #
  # Validation is a SEPARATE pass that emits an "invalid" marker per bad record: jq
  # reports a runtime error() per input but STILL EXITS 0 over multiple file
  # arguments, so we COUNT markers rather than rely on error(). A malformed-JSON parse
  # error is a hard jq failure (non-zero exit) and aborts here too.
  local _invalid
  if ! _invalid="$(jq -r '
        if type != "object" then "invalid"
        else
          (.kind // "token_usage") as $k
          | if ($k == "finding_verification" or $k == "lsp_cold_start" or $k == "gemini_key_cooldown"
                or $k == "gemini_attempt" or $k == "gemini_rejection_sample") then empty
            elif $k == "token_usage" then
              # ts must be a canonical, valid UTC instant (a "2026-09-26garbage" string
              # would sort in-window lexically); token counts must be non-negative
              # integers (a negative count would subtract from the call cost).
              # duration_ms, when present, must be a non-negative number (not null or string).
              (def cnt: type == "number" and . >= 0 and . == floor;
               if ((.ts | type) == "string"
                   and (.ts | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
                   and ((.ts | try (fromdateiso8601 | todateiso8601) catch null) == .ts)
                   and (.workflow | type) == "string"
                   and (.tier | type) == "string"
                   and (.model | type) == "string" and (.model | length) > 0
                   and (.input_tokens | cnt) and (.cache_read_tokens | cnt)
                   and (.cache_creation_tokens | cnt) and (.output_tokens | cnt)
                   and ((.duration_ms == null) or ((.duration_ms | type) == "number" and .duration_ms >= 0)))
               then empty else "invalid" end)
            else "invalid" end
        end' "${files[@]}" 2>/dev/null)"; then
    return 1
  fi
  [ -z "$_invalid" ] || return 1

  # Emit pass: one enriched TSV row per token_usage record; non-token audit kinds are
  # skipped. Validation above guarantees every emitted record is complete.
  # Join with the ASCII unit separator (0x1F), NOT a tab: bash `read` treats tab as
  # IFS whitespace and collapses runs of it, so a record with an empty context and a
  # populated duration_ms would shift duration into ctx and lose it. A non-whitespace
  # delimiter preserves every field, empty ones included (#1953).
  jq -r 'select(type == "object")
    | select((.kind // "token_usage") == "token_usage")
    | [ (.ts // "-"), (.workflow // "-"), (.tier // "-"), (.model // "-"),
        (.input_tokens // 0 | tostring), (.cache_read_tokens // 0 | tostring),
        (.cache_creation_tokens // 0 | tostring), (.output_tokens // 0 | tostring),
        (.context // ""),
        (if (.duration_ms == null) then "" else (.duration_ms | tostring) end)
      ] | join("\u001f")' "${files[@]}" 2>/dev/null \
  | awk -F'\037' -v OFS='\t' -v table="${PRICING_TABLE:-}" '
      # One awk pass with the dated price table loaded once (same selection rule as
      # price_for: most-specific glob, ties -> latest effective_from) — not a price_for
      # subprocess plus two cost awks per record.
      function glob2re(g,   re) {
        re = g
        gsub(/[.[\]()^$+{}|\\]/, "\\\\&", re); gsub(/\*/, ".*", re); gsub(/\?/, ".", re)
        return "^" re "$"
      }
      function israte(v) { return v ~ /^[0-9]+(\.[0-9]+)?$/ }
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
        d = substr($1, 1, 10); bs = -1; be = ""; bi = 0
        for (i = 1; i <= nr; i++)
          if ($4 ~ gre[i] && eff[i] <= d)
            if (spec[i] > bs || (spec[i] == bs && eff[i] > be)) { bs = spec[i]; be = eff[i]; bi = i }
        # A matched row with any non-numeric/negative rate is UNPRICED, never coerced
        # to a zero rate (which would fabricate a cheap candidate).
        if (bi > 0 && israte(tin[bi]) && israte(tcr[bi]) && israte(tcw[bi]) && israte(tout[bi])) {
          cost = sprintf("%.6f", ($5 * tin[bi] + $6 * tcr[bi] + $7 * tcw[bi] + $8 * tout[bi]) / 1000000)
          crcost = sprintf("%.6f", $6 * tcr[bi] / 1000000)
          known = 1
        } else { cost = "-1"; crcost = "-1"; known = 0 }
        print $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, cost, crcost, known
      }'
}

# _canary_arm_metrics <enriched_arm_file>  (stdout: one TSV metrics row)
# Columns: inv prs priced unpriced mean_cost p50_cost mean_cr p50_cr
#          mean_dur p50_dur durc total_cost usd_per_minput
# -1 marks an undefined mean/median (no priced rows / no durations).
_canary_arm_metrics() {
  awk -F'\t' '
    function qsort(a, lo, hi,   i, j, p, t) {
      # In-place quicksort — O(n log n) average, so the incumbent arm (which can
      # collect thousands of records over the 14-day baseline) does not hit the
      # O(n^2) wall the old bubble sort did.
      if (lo >= hi) return
      i = lo; j = hi; p = a[int((lo + hi) / 2)]
      while (i <= j) {
        while (a[i] < p) i++
        while (a[j] > p) j--
        if (i <= j) { t = a[i]; a[i] = a[j]; a[j] = t; i++; j-- }
      }
      qsort(a, lo, j)
      qsort(a, i, hi)
    }
    function median(a, n,   i, b) {
      if (n <= 0) return -1
      for (i = 1; i <= n; i++) b[i] = a[i]
      qsort(b, 1, n)
      if (n % 2 == 1) return b[(n + 1) / 2]
      return (b[n / 2] + b[n / 2 + 1]) / 2
    }
    {
      inv++
      ctx = $9
      # Only canonical PR URLs are PR observations; other context strings (job IDs,
      # telemetry drift) must not inflate the distinct-PR count.
      if (ctx ~ /^https:\/\/github[.]com\/[^\/]+\/[^\/]+\/pull\/[0-9]+$/ && !(ctx in seen)) { seen[ctx] = 1; prs++ }
      if ($13 == 1) {
        priced++
        costs[priced] = $11 + 0; total_cost += $11 + 0
        crs[priced]   = $12 + 0; cr_total   += $12 + 0
        input_equiv  += ($5 + 0) + ($6 + 0)
      } else { unpriced++ }
      if ($10 != "") { durc++; durs[durc] = $10 + 0; dur_total += $10 + 0 }
    }
    END {
      mean_cost = (priced > 0) ? total_cost / priced : -1
      mean_cr   = (priced > 0) ? cr_total   / priced : -1
      mean_dur  = (durc   > 0) ? dur_total  / durc   : -1
      usd_per_m = (input_equiv > 0) ? total_cost / input_equiv * 1000000 : -1
      printf "%d\t%d\t%d\t%d\t%.6f\t%.6f\t%.6f\t%.6f\t%.3f\t%.3f\t%d\t%.6f\t%.6f\n",
        inv + 0, prs + 0, priced + 0, unpriced + 0,
        mean_cost, median(costs, priced), mean_cr, median(crs, priced),
        mean_dur, median(durs, durc), durc + 0, total_cost + 0, usd_per_m
    }'
}

# _bar_status <candidate_mean> <incumbent_mean> <bar_fraction>
# PASS when candidate is at least (bar) lower/better: cand <= inc * (1 - bar).
# INSUFFICIENT when the incumbent figure is not a positive number (no basis).
_bar_status() {
  awk -v c="$1" -v i="$2" -v bar="$3" 'BEGIN {
    if (i <= 0 || c < 0) { print "INSUFFICIENT"; exit }
    if (c <= i * (1 - bar)) print "PASS"; else print "FAIL"
  }'
}

# render_canary_report <jsonl_dir>
# Pure: filters by workflow/tier, splits arms by model, applies the sample
# windows + candidate cap, scores the three bars and prints the Markdown report.
# Returns 0 (PASS) / 1 (FAIL) / 2 (INSUFFICIENT). Configured via CANARY_* env
# (main() sets these from CLI flags; tests set them directly):
#   CANARY_CANDIDATE CANARY_INCUMBENT CANARY_WORKFLOW CANARY_TIER
#   CANARY_SINCE CANARY_UNTIL CANARY_BASELINE_SINCE CANARY_BASELINE_UNTIL
#   CANARY_MAX_PRS CANARY_MIN_PRS CANARY_MIN_INVOCATIONS
#   CANARY_COST_BAR CANARY_CACHE_BAR CANARY_LATENCY_BAR
#   CANARY_LABEL CANARY_MODE (real|controlled)
render_canary_report() {
  local dir="$1"
  local candidate incumbent workflow tier since until b_since b_until
  local max_prs min_prs min_inv cost_bar cache_bar latency_bar label mode
  candidate="${CANARY_CANDIDATE-}"
  incumbent="${CANARY_INCUMBENT-}"
  workflow="${CANARY_WORKFLOW:-pr-review}"
  tier="${CANARY_TIER:-deep}"
  since="${CANARY_SINCE-}"
  until="${CANARY_UNTIL-}"
  b_since="${CANARY_BASELINE_SINCE-}"
  b_until="${CANARY_BASELINE_UNTIL-}"
  max_prs="${CANARY_MAX_PRS-10}"
  min_prs="${CANARY_MIN_PRS-5}"
  min_inv="${CANARY_MIN_INVOCATIONS-5}"
  cost_bar="${CANARY_COST_BAR-0.20}"
  cache_bar="${CANARY_CACHE_BAR-0.50}"
  latency_bar="${CANARY_LATENCY_BAR-0.20}"
  label="${CANARY_LABEL-Canary go/no-go — real PRs}"
  mode="${CANARY_MODE-real}"

  if [ -z "$candidate" ] || [ -z "$incumbent" ]; then
    echo "ERROR: both a candidate and an incumbent model are required (--candidate / --incumbent)." >&2
    return 3
  fi
  case "$mode" in
    real|controlled) ;;
    *) echo "ERROR: CANARY_MODE must be 'real' or 'controlled' (got '${mode}')." >&2; return 3 ;;
  esac
  # Bars are fractions in [0,1]; sample floors / cap are integers. A malformed value
  # would be coerced to zero by awk/[ ] and could turn a thin sample into a PASS.
  local _b
  for _b in "$cost_bar" "$cache_bar" "$latency_bar"; do
    if ! awk -v v="$_b" 'BEGIN { exit !(v ~ /^[0-9]+(\.[0-9]+)?$/ && v + 0 <= 1) }'; then
      echo "ERROR: bars must be numbers between 0 and 1 (got '${_b}')." >&2
      return 3
    fi
  done
  for _b in "$min_prs" "$min_inv"; do
    case "$_b" in
      ''|*[!0-9]*) echo "ERROR: --min-prs/--min-invocations must be non-negative integers (got '${_b}')." >&2; return 3 ;;
    esac
  done
  case "${max_prs#-}" in
    ''|*[!0-9]*) echo "ERROR: --candidate-max-prs must be an integer (got '${max_prs}')." >&2; return 3 ;;
  esac

  # Identical candidate/incumbent IDs make the two arms the same model over different
  # time windows — workload drift alone could then PASS. A misconfiguration, not a verdict.
  if [ "$candidate" = "$incumbent" ]; then
    echo "ERROR: --candidate and --incumbent must differ (both '${candidate}')." >&2
    return 3
  fi

  local enriched
  enriched="$(mktemp)" || { echo "ERROR: failed to create temporary file" >&2; return 3; }
  # main() calls render_canary_report in an `||` list, which disables errexit for the
  # whole function — so a failing canary_annotate (a malformed JSONL file, a jq error)
  # would NOT abort on its own and rendering would score whatever partial rows landed
  # in $enriched, possibly emitting a bogus PASS on corrupt evidence. Check it
  # explicitly and fail closed before any scoring (#1953). This is an OPERATIONAL
  # error (corrupt/structurally-invalid evidence), NOT a verdict — return the >2
  # operational code so the workflow distinguishes a failed run from a valid
  # INSUFFICIENT (which would leave the run green with an empty summary).
  if ! canary_annotate "$dir" > "$enriched"; then
    echo "ERROR: failed to annotate token-usage records in ${dir} — a malformed/structurally-invalid JSONL record or jq failure makes the sample partial; refusing to score incomplete evidence." >&2
    rm -f "$enriched"
    return 3
  fi

  # Split into candidate / incumbent / fallback arms, applying the sample windows.
  # In controlled mode both arms come from identical inputs, so windows + cap are
  # inert (empty windows) — the arms are split by model alone.
  #
  # Controlled mode ALSO wildcards the workflow/tier predicates. The model-ab
  # producer (scripts/evals/model-ab.sh) drives each arm through run_triage without
  # setting TOKEN_WORKFLOW, so its captured records carry workflow=unknown / tier=
  # triage — NOT the real-PR pr-review/deep labels. Filtering controlled records by
  # those real-PR labels dropped both arms and left --model-ab-dir permanently
  # INSUFFICIENT; controlled mode selects its paired records by model alone (#1953).
  local cand_file inc_file fb_file
  cand_file="$(mktemp)" || { echo "ERROR: failed to create temporary file" >&2; return 3; }
  inc_file="$(mktemp)"  || { echo "ERROR: failed to create temporary file" >&2; return 3; }
  fb_file="$(mktemp)"   || { echo "ERROR: failed to create temporary file" >&2; return 3; }

  local f_wf f_tier
  if [ "$mode" = "real" ]; then f_wf="$workflow"; f_tier="$tier"; else f_wf=""; f_tier=""; fi

  local c_since c_until
  if [ "$mode" = "real" ]; then c_since="$since"; c_until="$until"; else c_since=""; c_until=""; fi
  awk -F'\t' -v wf="$f_wf" -v tier="$f_tier" -v m="$candidate" \
      -v s="$c_since" -v u="$c_until" \
    '(wf == "" || $2 == wf) && (tier == "" || $3 == tier) && $4 == m {
       if (s != "" && $1 < s) next
       if (u != "" && $1 > u) next
       print
     }' "$enriched" > "$cand_file"

  local i_since i_until
  if [ "$mode" = "real" ]; then i_since="$b_since"; i_until="$b_until"; else i_since=""; i_until=""; fi
  awk -F'\t' -v wf="$f_wf" -v tier="$f_tier" -v m="$incumbent" \
      -v s="$i_since" -v u="$i_until" \
    '(wf == "" || $2 == wf) && (tier == "" || $3 == tier) && $4 == m {
       if (s != "" && $1 < s) next
       if (u != "" && $1 >= u) next
       print
     }' "$enriched" > "$inc_file"

  # Fallback = deep-tier calls in the CANDIDATE (canary) window that are NOT the
  # candidate model. In REAL mode this INCLUDES the incumbent: an incumbent call
  # after the canary cut (e.g. part of the rollout still on the old channel) is
  # excluded from the candidate arm by model AND from the incumbent arm by the
  # baseline window, so unless it is captured here it would vanish from the report
  # entirely — letting the remaining candidate records PASS while hiding evidence
  # that the rollout did not actually use the candidate (#1953). The candidate
  # window still bounds this, so pre-cut incumbent baseline records (before c_since)
  # are not double-counted as fallbacks. In CONTROLLED mode the incumbent IS a scored
  # arm (selected by model, no window), so it is excluded from the fallback list
  # there to avoid reporting a scored arm as a fallback.
  local fb_excl_inc=""
  [ "$mode" = "controlled" ] && fb_excl_inc="$incumbent"
  awk -F'\t' -v wf="$f_wf" -v tier="$f_tier" -v c="$candidate" -v xi="$fb_excl_inc" \
      -v s="$c_since" -v u="$c_until" \
    '(wf == "" || $2 == wf) && (tier == "" || $3 == tier) && $4 != c && (xi == "" || $4 != xi) {
       if (s != "" && $1 < s) next
       if (u != "" && $1 > u) next
       print
     }' "$enriched" > "$fb_file"

  # Candidate cap: keep only the first max_prs distinct PR contexts in time order
  # (earliest ts per context). Real mode only; a non-positive cap disables it.
  if [ "$mode" = "real" ] && [ "$max_prs" -gt 0 ]; then
    local allowed capped
    allowed="$(awk -F'\t' '$9 ~ /^https:\/\/github[.]com\/[^\/]+\/[^\/]+\/pull\/[0-9]+$/ { if (!($9 in first) || $1 < first[$9]) first[$9] = $1 }
                 END { for (k in first) printf "%s\t%s\n", first[k], k }' "$cand_file" \
               | sort -t$'\t' -k1,1 | awk -F'\t' -v n="$max_prs" 'NR <= n { print $2 }')"
    # Only apply the cap when at least one candidate record carries a context to
    # cap on. If every candidate record has an empty context, "allowed" is empty
    # and the awk filter would match nothing — mv'ing that empty file over
    # cand_file would silently drop all candidate data (→ a bogus INSUFFICIENT).
    # Leaving cand_file untouched lets the distinct-PR guard report the real state.
    # Once a cap applies, records with no context are dropped too: they are not PR
    # observations and would otherwise bypass the cap and skew cost/latency verdicts.
    if [ -n "$allowed" ]; then
      capped="$(mktemp)" || { echo "ERROR: failed to create temporary file" >&2; return 3; }
      awk -F'\t' -v allow="$allowed" 'BEGIN { n = split(allow, a, "\n"); for (k = 1; k <= n; k++) keep[a[k]] = 1 }
        $9 in keep { print }' "$cand_file" > "$capped"
      mv "$capped" "$cand_file"
    fi
  fi

  # Per-arm metrics.
  local cm im
  cm="$(_canary_arm_metrics < "$cand_file")"
  im="$(_canary_arm_metrics < "$inc_file")"
  [ -n "$cm" ] || cm=$'0\t0\t0\t0\t-1\t-1\t-1\t-1\t-1\t-1\t0\t0\t-1'
  [ -n "$im" ] || im=$'0\t0\t0\t0\t-1\t-1\t-1\t-1\t-1\t-1\t0\t0\t-1'

  local c_inv c_prs c_priced c_unpr c_mcost c_pcost c_mcr c_mdur c_pdur c_durc c_perm
  local i_inv i_prs i_priced i_unpr i_mcost i_pcost i_mcr i_mdur i_pdur i_durc i_perm
  # _pcr (p50 cache-read) and _tcost (arm total) are computed but not surfaced.
  IFS=$'\t' read -r c_inv c_prs c_priced c_unpr c_mcost c_pcost c_mcr _ c_mdur c_pdur c_durc _ c_perm <<< "$cm"
  IFS=$'\t' read -r i_inv i_prs i_priced i_unpr i_mcost i_pcost i_mcr _ i_mdur i_pdur i_durc _ i_perm <<< "$im"

  # Sample-size guard shared by every metric (never let a thin sample read as PASS).
  # Real mode counts DISTINCT candidate PRs (min_prs) because each real PR is one
  # independent observation. Controlled mode (model-ab) runs held-out cases without
  # a PR_URL context, so it has zero distinct PRs by construction — there the guard
  # is per-arm INVOCATIONS (min_inv), or every controlled run would be INSUFFICIENT.
  local base_insuff=0
  if [ "$mode" = "controlled" ]; then
    [ "$c_inv" -lt "$min_inv" ] && base_insuff=1
    [ "$i_inv" -lt "$min_inv" ] && base_insuff=1
  else
    [ "$c_prs" -lt "$min_prs" ] && base_insuff=1
    [ "$i_inv" -lt "$min_inv" ] && base_insuff=1
  fi

  # Any unpriced record has an UNKNOWN cost, so it is excluded from its arm's
  # mean-cost denominator — an arm with costly unpriced calls could otherwise show a
  # cheap mean over its priced subset and skew the comparison. This applies to BOTH
  # arms: unpriced INCUMBENT calls (e.g. a custom incumbent or a date window spanning
  # that model's pricing-effective boundary) would otherwise count toward the sample
  # while sitting outside the incumbent cost mean, letting the candidate earn a
  # misleading cost/cache PASS against only the priced incumbent subset. When either
  # arm carries unpriced records we cannot certify a genuine cost/cache win, so both
  # bars are INSUFFICIENT (never PASS on partial pricing) (#1953).
  local cost_status cache_status latency_status
  if [ "$base_insuff" -eq 1 ] || [ "$c_priced" -eq 0 ] || [ "$i_priced" -eq 0 ] || [ "$c_unpr" -gt 0 ] || [ "$i_unpr" -gt 0 ]; then
    cost_status="INSUFFICIENT"; cache_status="INSUFFICIENT"
  else
    cost_status="$(_bar_status "$c_mcost" "$i_mcost" "$cost_bar")"
    cache_status="$(_bar_status "$c_mcr" "$i_mcr" "$cache_bar")"
  fi
  # Latency needs the SAME sample floor as the other bars: it is not enough for each
  # arm to carry a single non-null duration. Require at least min_inv durations per
  # arm, so a five-invocation comparison with duration on only one call each stays
  # INSUFFICIENT instead of scoring a bogus one-pair PASS.
  # In real mode the candidate durations must also span min_prs DISTINCT PRs: raw
  # duration counts can come from retries of a single PR.
  local c_dur_prs=0
  if [ "$mode" = "real" ]; then
    c_dur_prs="$(awk -F'\t' '$10 != "" && $9 ~ /^https:\/\/github[.]com\/[^\/]+\/[^\/]+\/pull\/[0-9]+$/ && !($9 in s) { s[$9] = 1; n++ } END { print n + 0 }' "$cand_file")"
  fi
  if [ "$base_insuff" -eq 1 ] || [ "$c_durc" -lt "$min_inv" ] || [ "$i_durc" -lt "$min_inv" ] \
     || { [ "$mode" = "real" ] && [ "$c_dur_prs" -lt "$min_prs" ]; }; then
    latency_status="INSUFFICIENT"
  else
    latency_status="$(_bar_status "$c_mdur" "$i_mdur" "$latency_bar")"
  fi

  # Overall: a definite FAIL is a no-go; else any INSUFFICIENT is a no-go; else PASS.
  local overall rc
  if [ "$cost_status" = "FAIL" ] || [ "$cache_status" = "FAIL" ] || [ "$latency_status" = "FAIL" ]; then
    overall="FAIL"; rc=1
  elif [ "$cost_status" = "INSUFFICIENT" ] || [ "$cache_status" = "INSUFFICIENT" ] || [ "$latency_status" = "INSUFFICIENT" ]; then
    overall="INSUFFICIENT"; rc=2
  else
    overall="PASS"; rc=0
  fi

  # Reductions (candidate vs incumbent), for display.
  local cost_red cache_red lat_red
  cost_red="$(awk -v c="$c_mcost" -v i="$i_mcost" 'BEGIN { print (i > 0 && c >= 0) ? (i - c) / i : -999 }')"
  cache_red="$(awk -v c="$c_mcr" -v i="$i_mcr" 'BEGIN { print (i > 0 && c >= 0) ? (i - c) / i : -999 }')"
  lat_red="$(awk -v c="$c_mdur" -v i="$i_mdur" 'BEGIN { print (i > 0 && c >= 0) ? (i - c) / i : -999 }')"

  # ── Render ─────────────────────────────────────────────────────────────────
  printf '## %s\n\n' "$label"
  printf '_Candidate `%s` vs incumbent `%s` · workflow `%s` · tier `%s`_\n\n' \
    "$candidate" "$incumbent" "$workflow" "$tier"
  printf 'Priced per `scripts/lib/model-pricing.tsv` at each record'"'"'s date. '
  printf 'Bars: cost/inv ≥ %s lower · cache-read ≥ %s lower · latency ≥ %s better.\n\n' \
    "$(_fmt_pct "$cost_bar")" "$(_fmt_pct "$cache_bar")" "$(_fmt_pct "$latency_bar")"

  printf '### Per-arm figures\n\n'
  printf '| Metric | Candidate | Incumbent |\n|---|---:|---:|\n'
  printf '| Invocations | %s | %s |\n' "$(_fmt_int "$c_inv")" "$(_fmt_int "$i_inv")"
  printf '| Distinct PRs | %s | %s |\n' "$(_fmt_int "$c_prs")" "$(_fmt_int "$i_prs")"
  printf '| Unpriced records | %s | %s |\n' "$(_fmt_int "$c_unpr")" "$(_fmt_int "$i_unpr")"
  printf '| Mean USD / invocation | %s | %s |\n' "$(_fmt_usd_or_na "$c_mcost")" "$(_fmt_usd_or_na "$i_mcost")"
  printf '| p50 USD / invocation | %s | %s |\n' "$(_fmt_usd_or_na "$c_pcost")" "$(_fmt_usd_or_na "$i_pcost")"
  printf '| Mean cache-read USD / invocation | %s | %s |\n' "$(_fmt_usd_or_na "$c_mcr")" "$(_fmt_usd_or_na "$i_mcr")"
  printf '| Mean duration | %s | %s |\n' "$(_fmt_ms "$c_mdur")" "$(_fmt_ms "$i_mdur")"
  printf '| p50 duration | %s | %s |\n' "$(_fmt_ms "$c_pdur")" "$(_fmt_ms "$i_pdur")"
  printf '| USD / 1M input-equivalent tokens (context only) | %s | %s |\n\n' \
    "$(_fmt_usd_or_na "$c_perm")" "$(_fmt_usd_or_na "$i_perm")"

  printf '### Verdict per bar\n\n'
  printf '| Bar | Candidate | Incumbent | Reduction | Result |\n|---|---:|---:|---:|:--|\n'
  printf '| Cost per invocation (≥ %s lower) | %s | %s | %s | %s |\n' \
    "$(_fmt_pct "$cost_bar")" "$(_fmt_usd_or_na "$c_mcost")" "$(_fmt_usd_or_na "$i_mcost")" \
    "$( [ "$cost_red" = "-999" ] && printf 'n/a' || _fmt_pct "$cost_red" )" "$cost_status"
  printf '| Cache-read cost per invocation (≥ %s lower) | %s | %s | %s | %s |\n' \
    "$(_fmt_pct "$cache_bar")" "$(_fmt_usd_or_na "$c_mcr")" "$(_fmt_usd_or_na "$i_mcr")" \
    "$( [ "$cache_red" = "-999" ] && printf 'n/a' || _fmt_pct "$cache_red" )" "$cache_status"
  printf '| Latency / duration_ms (≥ %s better) | %s | %s | %s | %s |\n\n' \
    "$(_fmt_pct "$latency_bar")" "$(_fmt_ms "$c_mdur")" "$(_fmt_ms "$i_mdur")" \
    "$( [ "$lat_red" = "-999" ] && printf 'n/a' || _fmt_pct "$lat_red" )" "$latency_status"

  if [ "$latency_status" = "INSUFFICIENT" ]; then
    local lat_note=""
    [ "$c_durc" -lt "$min_inv" ] && lat_note="candidate (${c_durc} of ${min_inv} required duration_ms values)"
    if [ "$i_durc" -lt "$min_inv" ]; then
      [ -n "$lat_note" ] && lat_note="${lat_note} and "
      lat_note="${lat_note}incumbent (${i_durc} of ${min_inv} required duration_ms values)"
    fi
    [ -n "$lat_note" ] && printf 'Latency INSUFFICIENT: too few duration_ms values on the %s arm.\n\n' "$lat_note"
  fi

  # Fallback deep-tier calls (excluded from both arms) — listed, never merged.
  local fb_rows
  fb_rows="$(awk -F'\t' '{ c[$4]++ } END { for (k in c) printf "%s\t%d\n", k, c[k] }' "$fb_file" | sort)"
  if [ -n "$fb_rows" ]; then
    printf '### Deep-tier fallback calls (excluded from both arms)\n\n'
    printf '| Model | Calls |\n|---|---:|\n'
    while IFS=$'\t' read -r fbm fbc; do
      [ -n "$fbm" ] || continue
      printf '| `%s` | %s |\n' "$fbm" "$(_fmt_int "$fbc")"
    done <<< "$fb_rows"
    printf '\n'
  fi

  # Machine-readable verdict block (stable tokens for scripting / tests).
  printf '### Machine-readable verdict\n\n'
  printf '```\n'
  printf -- '- candidate invocations: %s\n' "$c_inv"
  printf -- '- candidate distinct PRs: %s\n' "$c_prs"
  printf -- '- candidate unpriced records: %s\n' "$c_unpr"
  printf -- '- incumbent invocations: %s\n' "$i_inv"
  printf -- '- incumbent distinct PRs: %s\n' "$i_prs"
  printf -- '- incumbent unpriced records: %s\n' "$i_unpr"
  printf -- '- cost: %s\n' "$cost_status"
  printf -- '- cache_read: %s\n' "$cache_status"
  printf -- '- latency: %s\n' "$latency_status"
  printf '```\n\n'
  printf '**Overall verdict:** %s (exit %s)\n\n' "$overall" "$rc"

  rm -f "$enriched" "$cand_file" "$inc_file" "$fb_file"
  return "$rc"
}

# ---------------------------------------------------------------------------
# Network I/O (main)
# ---------------------------------------------------------------------------

ARTIFACT_OP_TIMEOUT="${ARTIFACT_OP_TIMEOUT:-60}"

# collect_repo_jsonl <repo> <since> <jsonl_dir>  (stdout: artifact_count)
# Lists <repo>'s token-usage-* artifacts uploaded at/after <since> and downloads/
# extracts them into jsonl_dir, REUSING token_report.sh's per-artifact helpers.
#
# There is deliberately NO artifact upper bound. An artifact's created_at is its
# UPLOAD time (end of run), strictly LATER than the .ts of the calls it records, so
# a review call made just before an --until cutoff uploads its artifact AFTER the
# cutoff; bounding the download on created_at <= until would silently drop valid
# in-window calls and could then PASS an incomplete sample. The exact upper cutoff
# is enforced later, on each record's .ts, by the renderer's sample windows — never
# on upload time (#1953). The lower bound is sound: an artifact uploaded before
# <since> cannot hold a record with .ts >= <since> (a call's .ts always precedes its
# upload), so excluding it drops nothing.
#
# A failed listing is fatal (returns 1) — a canary must never score a
# silently-empty download as data. A PARTIAL download is fatal too (returns 1): if
# any selected artifact yields no records (download/extract failure — the shared
# helper only warns), the sample is incomplete and scoring it could report a PASS
# on missing evidence, so we refuse rather than score partial data.
collect_repo_jsonl() {
  local repo="$1" since="$2" jsonl_dir="$3"
  # Fail loudly if the target directory cannot be created (e.g. --collect-only --dir
  # pointing at an unwritable path). An ignored mkdir failure combined with a repo
  # that currently has zero selected artifacts would count 0/0 and report a
  # successful collection into a directory that does not exist (#1953).
  if ! mkdir -p "$jsonl_dir"; then
    echo "ERROR: could not create artifact directory: ${jsonl_dir}" >&2
    return 1
  fi

  local workdir; workdir="$(mktemp -d)" || { echo "ERROR: failed to create temporary directory" >&2; return 1; }
  # shellcheck disable=SC2064
  trap "rm -rf '$workdir'; trap - RETURN" RETURN
  export ARTIFACT_OP_TIMEOUT
  export COLLECT_JSONL_DIR="$jsonl_dir" COLLECT_WORKDIR="$workdir"
  export COLLECT_MARKER_DIR="$workdir/markers"
  mkdir -p "$COLLECT_MARKER_DIR"

  local ids
  if ! ids="$(_gh_timeout api "repos/${repo}/actions/artifacts" --paginate 2>/dev/null \
      | jq -r --arg s "$since" \
        '.artifacts[]
         | select(.name | startswith("token-usage-"))
         | select(.expired == false)
         | select(.created_at >= $s)
         | .id | tostring')"; then
    echo "ERROR: could not list token-usage artifacts for ${repo} — verify GH_TOKEN has actions:read." >&2
    return 1
  fi

  # Bounded-parallel download (same as token_report.sh's collector) so a slow
  # artifact set cannot serially consume the job timeout.
  local requested=0
  requested="$(printf '%s\n' "$ids" | grep -c . || true)"
  export -f _collect_one_artifact _gh_timeout _extract_zip
  printf '%s\n' "$ids" | grep . \
    | xargs -P "${COLLECT_CONCURRENCY:-8}" -I {} bash -c '_collect_one_artifact "$1" "$2"' _ "$repo" {} || true

  local collected
  collected="$(find "$COLLECT_MARKER_DIR" -type f | wc -l | tr -d ' ')"
  if [ "$collected" -lt "$requested" ]; then
    echo "ERROR: only ${collected}/${requested} selected token-usage artifacts for ${repo} yielded records — download/extract failures make the sample partial; refusing to score incomplete evidence." >&2
    return 1
  fi
  printf '%s\n' "$collected"
}

_usage() {
  # Print the leading comment block dynamically: drop the shebang (line 1), stop at
  # the first non-comment line, and strip the leading "# ". Hardcoding a line range
  # (e.g. 2,60p) truncates the header — the Usage examples live past line 60 — and
  # rots whenever the comment length changes.
  sed -e '1d' -e '/^[^#]/,$d' -e 's/^# \{0,1\}//' "${BASH_SOURCE[0]}"
}

main() {
  local repo="petry-projects/.github-private"
  local candidate="${CANARY_CANDIDATE-}" incumbent="${CANARY_INCUMBENT-}"
  local workflow="pr-review" tier="deep"
  local since="" until=""
  local b_since="" b_until="" b_days="14"
  local max_prs="10"
  local min_prs="${CANARY_MIN_PRS-5}" min_inv="${CANARY_MIN_INVOCATIONS-5}"
  local cost_bar="${CANARY_COST_BAR-0.20}" cache_bar="${CANARY_CACHE_BAR-0.50}" latency_bar="${CANARY_LATENCY_BAR-0.20}"
  local dir="" model_ab_dir="" collect_only="false"

  while [ "$#" -gt 0 ]; do
    # A value-taking option with no value is an operational error (64), not a
    # `set -u` abort (exit 1), which the workflow would read as a FAIL verdict.
    case "$1" in
      --repo|--candidate|--incumbent|--workflow|--tier|--since|--until|--baseline-since|--baseline-until|--baseline-days|--candidate-max-prs|--min-prs|--min-invocations|--cost-bar|--cache-bar|--latency-bar|--dir|--model-ab-dir)
        if [ "$#" -lt 2 ]; then echo "ERROR: $1 requires a value." >&2; return 64; fi ;;
    esac
    case "$1" in
      --repo)            repo="$2"; shift 2 ;;
      --candidate)       candidate="$2"; shift 2 ;;
      --incumbent)       incumbent="$2"; shift 2 ;;
      --workflow)        workflow="$2"; shift 2 ;;
      --tier)            tier="$2"; shift 2 ;;
      --since)           since="$2"; shift 2 ;;
      --until)           until="$2"; shift 2 ;;
      --baseline-since)  b_since="$2"; shift 2 ;;
      --baseline-until)  b_until="$2"; shift 2 ;;
      --baseline-days)   b_days="$2"; shift 2 ;;
      --candidate-max-prs) max_prs="$2"; shift 2 ;;
      --min-prs)         min_prs="$2"; shift 2 ;;
      --min-invocations) min_inv="$2"; shift 2 ;;
      --cost-bar)        cost_bar="$2"; shift 2 ;;
      --cache-bar)       cache_bar="$2"; shift 2 ;;
      --latency-bar)     latency_bar="$2"; shift 2 ;;
      --dir)             dir="$2"; shift 2 ;;
      --model-ab-dir)    model_ab_dir="$2"; shift 2 ;;
      --collect-only)    collect_only="true"; shift ;;
      -h|--help)         _usage; return 0 ;;
      *) echo "ERROR: unknown argument: $1" >&2; return 64 ;;
    esac
  done

  if [ "$collect_only" != "true" ] && { [ -z "$candidate" ] || [ -z "$incumbent" ]; }; then
    echo "ERROR: --candidate <candidate-model> and --incumbent <incumbent-model> are required." >&2
    echo "Usage: canary_report.sh --candidate <model> --incumbent <model> [--since ISO] [--dir PATH] (see --help)" >&2
    return 3
  fi
  if [ "$candidate" = "$incumbent" ] && [ -n "$candidate" ]; then
    echo "ERROR: --candidate and --incumbent must differ (both '${candidate}')." >&2
    return 64
  fi
  case "$b_days" in
    ''|*[!0-9]*) echo "ERROR: --baseline-days must be a positive integer (got '${b_days}')." >&2; return 64 ;;
  esac
  [ "$b_days" -gt 0 ] || { echo "ERROR: --baseline-days must be a positive integer." >&2; return 64; }

  # Canonicalize every ISO bound to UTC seconds precision up front so the collector
  # (jq) and the renderer (awk) compare bounds and record timestamps consistently. A
  # bound we cannot compare safely (numeric offset or fractional seconds) is rejected
  # here rather than silently mis-windowed (#1953).
  since="$(_norm_iso "$since")"     || return 64
  until="$(_norm_iso "$until")"     || return 64
  b_since="$(_norm_iso "$b_since")" || return 64
  b_until="$(_norm_iso "$b_until")" || return 64

  # Validate --candidate-max-prs is an integer BEFORE scoring. render_canary_report
  # tests it with `[ "$max_prs" -gt 0 ]`, and because rendering runs from an `||`
  # list (errexit disabled), a nonnumeric value would only print "integer expression
  # expected", evaluate false, silently DISABLE the cap and continue — emitting a
  # possible PASS over an unintended, uncapped sample. Fail loudly instead (#1953).
  # A non-positive integer is allowed and intentionally disables the cap.
  case "${max_prs#-}" in
    ''|*[!0-9]*)
      echo "ERROR: --candidate-max-prs must be an integer (got '${max_prs}')." >&2
      return 64 ;;
  esac

  # The canary window starts at the cut (== the baseline end). When --since is
  # omitted, default the candidate lower bound to it so pre-canary candidate
  # records never enter the candidate arm, even though collection still spans the
  # full baseline window below (an empty lower bound would admit them — #1953).
  # Derive the baseline window when not given explicitly: --baseline-days ending at
  # --since (or at --baseline-until when only that is given).
  if [ -z "$b_until" ]; then b_until="$since"; fi
  if [ -z "$b_since" ] && [ -n "$b_until" ]; then
    b_since="$(date -u -d "${b_until/Z/} UTC - ${b_days} days" +%Y-%m-%dT%H:%M:%SZ)" \
      || { echo "ERROR: could not derive the baseline window." >&2; return 64; }
  fi
  [ -z "$since" ] && since="$b_until"
  # Without a cut both windows would be unbounded (collection falls back to 1970) and
  # the report would compare all retained history rather than canary vs baseline.
  # Local snapshots (--dir / --model-ab-dir) do no collection, so only live runs need it.
  if [ -z "$since" ] && [ -z "$b_until" ] && { [ "$collect_only" = "true" ] || { [ -z "$dir" ] && [ -z "$model_ab_dir" ]; }; }; then
    echo "ERROR: --since (the canary cut) or --baseline-until is required." >&2
    return 64
  fi

  # An explicitly supplied local input directory must exist and be readable. A
  # misspelled/unreadable path would otherwise glob to zero rows and render an
  # ordinary INSUFFICIENT, making a bad path indistinguishable from empty evidence.
  # (--collect-only creates --dir, so this check is scoped to the scoring paths.)
  if [ "$collect_only" != "true" ] && [ -n "$dir" ] && { [ ! -d "$dir" ] || [ ! -r "$dir" ] || [ ! -x "$dir" ]; }; then
    echo "ERROR: --dir path does not exist or is not a readable directory: $dir" >&2
    return 66
  fi
  if [ -n "$model_ab_dir" ] && { [ ! -d "$model_ab_dir" ] || [ ! -r "$model_ab_dir" ] || [ ! -x "$model_ab_dir" ]; }; then
    echo "ERROR: --model-ab-dir path does not exist or is not a readable directory: $model_ab_dir" >&2
    return 66
  fi

  export CANARY_CANDIDATE="$candidate" CANARY_INCUMBENT="$incumbent"
  export CANARY_WORKFLOW="$workflow" CANARY_TIER="$tier"
  export CANARY_SINCE="$since" CANARY_UNTIL="$until"
  export CANARY_BASELINE_SINCE="$b_since" CANARY_BASELINE_UNTIL="$b_until"
  export CANARY_MAX_PRS="$max_prs" CANARY_MIN_PRS="$min_prs" CANARY_MIN_INVOCATIONS="$min_inv"
  export CANARY_COST_BAR="$cost_bar" CANARY_CACHE_BAR="$cache_bar" CANARY_LATENCY_BAR="$latency_bar"

  # Collection lower bound: the download starts at the earlier of the candidate and
  # baseline window starts so a single collection feeds both arms. There is no upper
  # bound on the download — collection runs through "now" and the exact upper cutoff
  # (--until) is applied later on each record's .ts by the renderer, so calls uploaded
  # just after the cutoff are not lost (#1953).
  local scored_dir="" own_tmp="" col_since count
  col_since="$b_since"
  if [ -z "$col_since" ] || { [ -n "$since" ] && [[ "$since" < "$col_since" ]]; }; then col_since="$since"; fi
  [ -n "$col_since" ] || col_since="1970-01-01T00:00:00Z"

  # --collect-only snapshots artifacts to a persistent directory and exits without
  # scoring; it REQUIRES --dir. A temp dir would be wiped by the EXIT trap before
  # the advertised snapshot could be reused, so refuse rather than silently lose it.
  if [ "$collect_only" = "true" ]; then
    if [ -z "$dir" ]; then
      echo "ERROR: --collect-only requires --dir <path> to persist the snapshot." >&2
      return 64
    fi
    echo "Collecting token-usage artifacts for ${repo} (uploaded ≥ ${col_since} → now)..." >&2
    if ! count="$(collect_repo_jsonl "$repo" "$col_since" "$dir")"; then
      echo "ERROR: artifact collection failed for ${repo}." >&2
      return 3
    fi
    echo "Collected ${count} artifact(s) into ${dir}." >&2
    echo "collect-only: score later with --dir ${dir}." >&2
    return 0
  fi

  # Resolve the real-PR section's directory: a local snapshot (--dir) or a fresh
  # windowed download into a temp dir cleaned up on EXIT.
  if [ -n "$dir" ]; then
    scored_dir="$dir"
  elif [ -n "$model_ab_dir" ]; then
    : # controlled-only invocation: no live collection or credentials needed
  else
    own_tmp="$(mktemp -d)" || { echo "ERROR: failed to create temporary directory" >&2; return 3; }
    # shellcheck disable=SC2064
    trap "rm -rf '$own_tmp'" EXIT
    echo "Collecting token-usage artifacts for ${repo} (uploaded ≥ ${col_since} → now)..." >&2
    if ! count="$(collect_repo_jsonl "$repo" "$col_since" "$own_tmp")"; then
      echo "ERROR: artifact collection failed for ${repo}." >&2
      return 3
    fi
    echo "Collected ${count} artifact(s)." >&2
    scored_dir="$own_tmp"
  fi

  local rc=0
  if [[ -n "$scored_dir" ]]; then
    CANARY_MODE="real" CANARY_LABEL="Canary go/no-go — real PRs" \
      render_canary_report "$scored_dir" || rc="$?"
  fi

  # Controlled model-ab section — a separate report, never merged with the above.
  if [[ -n "$model_ab_dir" ]]; then
    local ab_rc=0
    CANARY_MODE="controlled" \
    CANARY_LABEL="Controlled comparison — model-ab (identical inputs)" \
      render_canary_report "$model_ab_dir" || ab_rc="$?"
    # Combine the two verdicts: a controlled FAIL is a no-go even when the real-PR
    # section passes. (scored_dir is always set, so the exit code must reflect BOTH
    # sections rather than the real-PR one alone.)
    rc="$(_combine_verdict "$rc" "$ab_rc")"
  fi

  return "$rc"
}

# Only run main when executed directly (not when sourced by tests).
if [[ "${BASH_SOURCE[0]}" = "${0}" ]]; then
  main "$@"
fi
