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
#   ORG=combsmith LOOKBACK_DAYS=7 GH_TOKEN=<pat> bash scripts/token_report.sh > report.md
#
# Environment:
#   ORG            — GitHub org to scan (default: combsmith)
#   LOOKBACK_DAYS  — rolling window of artifact history to include (default: 7)
#   GH_TOKEN       — PAT with actions:read across the org (artifacts are per-repo)
#   TOKEN_REPORT_OUT — optional path; when set, the report is written there in addition
#                      to stdout.
#
# ET formula (GitHub's framework): ET = m × (1.0×I + 0.1×C + 4.0×O)
# The `et` field is precomputed per call by token-metrics.sh; this script only sums it.

set -euo pipefail

ORG="${ORG:-combsmith}"
LOOKBACK_DAYS="${LOOKBACK_DAYS:-7}"

# ---------------------------------------------------------------------------
# Pricing — load the dated price table so cost + ET share one source of truth.
# ---------------------------------------------------------------------------
if [ -f "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/model-pricing.sh" ]; then
  # shellcheck source=scripts/lib/model-pricing.sh
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/model-pricing.sh"
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
#   12 cache_write  13 date (YYYY-MM-DD)
# ET is recomputed here from the table (m = input(model)/input(haiku)), so it can never
# drift from the dollar figure.
annotate_records() {
  local dir="$1"
  local files=("$dir"/*.jsonl)
  [ -e "${files[0]}" ] || return 0   # no JSONL files → no rows
  jq -r 'select(type == "object") | [
      (.repo // "unknown"), (.workflow // "unknown"), (.tier // "-"), (.model // "-"),
      (.input_tokens // 0), (.cache_read_tokens // 0), (.output_tokens // 0),
      (.ts // "-"), (.context // ""), (.cache_creation_tokens // 0)
    ] | @tsv' "${files[@]}" 2>/dev/null \
  | awk -F'\t' -v table="${PRICING_TABLE:-}" -v baseline="${ET_BASELINE_MODEL:-claude-haiku-4-5}" '
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
        cw = $10 + 0
        mi = best_idx(model, d)
        bi = best_idx(baseline, d)
        bpin = (bi > 0) ? tin[bi] : 0
        if (mi > 0) {
          known = 1
          cost = (inp * tin[mi] + ca * tcr[mi] + cw * tcw[mi] + out * tout[mi]) / 1000000
          m = (bpin > 0) ? tin[mi] / bpin : 1.0
        } else { known = 0; cost = -1; m = 1.0 }
        et = m * (1.0 * inp + 0.1 * ca + 4.0 * out)
        # Enriched cols 1-11 unchanged for downstream; cache_write=12, date=13 appended.
        printf "%s\t%s\t%s\t%s\t%d\t%d\t%d\t%.6f\t%.4f\t%d\t%s\t%d\t%s\n",
          repo, wf, tier, model, inp, ca, out, cost, et, known, ctx, cw, d
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
    printf 'No token-usage records found in the last %s days.\n' "$lookback"
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
  printf '| Workflow | Tier | Model | Calls | Input | Cache | Output | Cost | %% of $ | ET |\n'
  printf '|---|---|---|---:|---:|---:|---:|---:|---:|---:|\n'
  awk -F'\t' '{ k = $2"\t"$3"\t"$4
      calls[k]++; inp[k] += $5; ca[k] += $6; out[k] += $7; et[k] += $9
      if ($10 == 1) cost[k] += $8; else unk[k]++ }
    END { for (k in calls)
      printf "%.6f\t%.4f\t%d\t%d\t%d\t%d\t%d\t%s\n",
        cost[k], et[k], calls[k], inp[k], ca[k], out[k], unk[k], k }' "$enriched" \
  | sort -t$'\t' -k1,1rn \
  | while IFS=$'\t' read -r cost et calls input cache output unk wf tier model; do
      local pct mark=""; [ "$unk" -gt 0 ] && mark="*"
      pct="$(awk -v c="$cost" -v t="$total_cost" 'BEGIN { printf "%d%%", (t > 0 ? c / t * 100 : 0) }')"
      printf '| `%s` | %s | `%s` | %s | %s | %s | %s | %s%s | %s | %s |\n' \
        "$wf" "$tier" "$model" "$(_fmt_int "$calls")" "$(_fmt_int "$input")" \
        "$(_fmt_int "$cache")" "$(_fmt_int "$output")" "$(_fmt_usd "$cost")" "$mark" "$pct" "$(_fmt_int "$et")"
    done
  printf '\n'

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

# collect_org_jsonl <jsonl_dir>  (stdout: "<repo_count> <artifact_count>")
# Discovers non-archived repos, downloads each token-usage artifact inside the
# lookback window, extracts its JSONL, and tags every record with its source repo.
collect_org_jsonl() {
  local jsonl_dir="$1"
  mkdir -p "$jsonl_dir"

  local repos_raw
  if ! repos_raw="$(gh api "orgs/${ORG}/repos?per_page=100&type=all" --paginate \
    --jq '.[] | select(.archived == false) | .full_name')"; then
    echo "ERROR: org repo discovery for '${ORG}' failed — verify GH_TOKEN has org read access." >&2
    return 1
  fi
  [ -n "$repos_raw" ] || { echo "0 0"; return 0; }

  local cutoff repo_count=0 artifact_count=0
  cutoff="$(date -u -d "${LOOKBACK_DAYS} days ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -v-"${LOOKBACK_DAYS}"d +%Y-%m-%dT%H:%M:%SZ)"

  local workdir; workdir="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$workdir'" RETURN

  local repo
  while IFS= read -r repo; do
    [ -n "$repo" ] || continue
    repo_count=$((repo_count + 1))

    local arts
    arts="$(gh api "repos/${repo}/actions/artifacts" --paginate 2>/dev/null \
      | jq -r --arg cutoff "$cutoff" \
      '.artifacts[] | select(.name | startswith("token-usage-")) | select(.expired == false) | select(.created_at >= $cutoff) | .id | tostring')" || {
      echo "WARN: could not fetch artifacts for ${repo} — skipping (check actions:read permission)" >&2
      continue
    }
    [ -n "$arts" ] || continue

    local id
    while IFS= read -r id; do
      [ -n "$id" ] || continue

      local zip="$workdir/a-$id.zip" ex="$workdir/x-$id"
      mkdir -p "$ex"
      if ! gh api "repos/${repo}/actions/artifacts/${id}/zip" > "$zip" 2>/dev/null; then
        echo "WARN: artifact ${id} from ${repo} — download failed; skipping (report may be incomplete)" >&2
        continue
      fi
      if ! _extract_zip "$zip" "$ex" 2>/dev/null; then
        echo "WARN: artifact ${id} from ${repo} — extraction failed; skipping (report may be incomplete)" >&2
        continue
      fi

      local found=false f dest
      while IFS= read -r f; do
        # Tag each record with its source repo for the by-repo rollup.
        dest="$jsonl_dir/${id}-$(basename "$f")"
        if jq -c --arg repo "$repo" 'select(type=="object") | . + {repo: $repo}' \
            "$f" > "$dest" 2>/dev/null; then
          found=true
        else
          # jq creates the destination before it can fail on malformed input;
          # remove it so annotate_records never sees a corrupt *.jsonl file.
          rm -f "$dest" 2>/dev/null || true
        fi
      done < <(find "$ex" -type f -name '*.jsonl' -print)
      [ "$found" = true ] && artifact_count=$((artifact_count + 1))

      rm -rf "$zip" "$ex"
    done <<< "$arts"
  done <<< "$repos_raw"

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
