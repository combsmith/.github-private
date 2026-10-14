# Token Cost Observatory — Weekly Report

Org-wide visibility into LLM token spend for the agentic workflows (pr-review and
dev-lead). Builds on the per-call JSONL logging added by the
[Token Cost Observatory](https://github.com/petry-projects/.github-private/discussions/332)
work — this layer aggregates that data across **every repo in the org** and
delivers it where humans actually look.

## The problem it solves

The agents emit a token-usage record per LLM call (`scripts/lib/token-metrics.sh`)
and upload it as a `token-usage-<run_id>` artifact. But because pr-review and
dev-lead run as **reusable workflows in each caller repo**, those artifacts land in
the *caller's* repo — not in `.github-private`. The original inline summary only
scanned `.github-private`, so it saw a few percent of real org spend. This report
scans all non-archived repos.

## Cost (USD)

The report shows **estimated USD cost** alongside tokens, everywhere tokens are
surfaced: totals, by workflow/tier/model, by repository, a **cost-per-day stacked-by-repo
chart**, and a most-expensive-PRs rollup (with the first 35 chars of each PR title). Cost
is the headline metric; ET is kept as a normalised comparator.

**Formatting (org standard):** all surfaced dollar amounts are rounded to **2 decimals
(cents)** via a single formatter (`_fmt_usd`, `printf "$%.2f"`) — see
[AGENTS.md → Cost reporting](../AGENTS.md). Sub-cent values render as `$0.00`; use ET for
finer granularity.

The **cost-per-day chart** is an ASCII stacked bar (one bar per day, length scaled to the
priciest day, segments lettered per top repo with the rest bucketed as `.`) — GitHub
Markdown / Mermaid has no native stacked-bar type, so an ASCII bar inside a fenced block
renders reliably everywhere. PR titles are fetched once (top-10 PRs) by `main()` and passed
to the pure renderer via `PR_TITLE_FILE`.

### Single source of truth: `scripts/lib/model-pricing.tsv`

All prices live in one git-versioned table — prices are **data, not code**, so every
change is a reviewed PR with full history. `scripts/lib/model-pricing.sh` is the only
place token counts become dollars (`cost_usd`) or ET multipliers (`et_multiplier_for`),
so cost and ET can never drift apart.

```
cost = (input × P_in + cache_read × P_cache + output × P_out) / 1,000,000
```

### Effective-dated pricing

Each table row carries an `effective_from` date. A record is priced at **the rate in
effect on its own timestamp** — not today's rate. For model `M` at time `T`, the lookup
picks the row whose glob matches `M` and whose `effective_from ≤ T`, choosing the most
specific glob (ties → latest date). Selection is deterministic, so a given record always
resolves to the same price.

**To change a price:** never edit an existing row — **append** a new row for the same
glob with a later `effective_from`. Records before that date keep their historical rate;
later records pick up the new rate automatically. Example (Sonnet drops on 2026-09-01):

```
claude-sonnet-4-*    2025-01-01    3.00    0.30    3.75    15.00
claude-sonnet-4-*    2026-09-01    2.50    0.25    3.125   12.50   # ← append, don't edit
```

(Columns: `input  cache_read  cache_write  output`, USD/MTok.)

### Real token usage (incl. cache)

Cost is computed from **actual API usage**, not estimates. When `TOKEN_LOG_FILE` is set,
`scripts/engine.sh` runs Claude/Gemini with `--output-format json`, extracts the model's
text for downstream consumers, and records the real `input` / `cache_read` /
`cache_write` (cache-creation) / `output` token counts (`scripts/lib/token-metrics.sh:
parse_engine_usage`). This replaced the earlier `char_count / 4` estimate, which always
reported zero cache.

- **Safety switch:** set `ENGINE_USAGE_JSON=0` to instantly revert to text output + the
  estimate path (no code change). JSON capture only engages when `TOKEN_LOG_FILE` is set,
  and falls back to the raw output if extraction yields nothing — so a parse hiccup never
  breaks a review.
- **Copilot:** the GitHub Copilot CLI exposes no machine-readable token usage, so copilot
  runs remain estimate-based (cache = 0). This is a CLI limitation, not a gap in the report.
- **Cache-write** (cache-creation, billed at 1.25× input by Anthropic) is now both captured
  and priced. One-shot agent calls typically show more cache-write than cache-read.

### Reliability guarantees

- **Unknown model → never silent $0.** Calls with no matching price row are excluded
  from cost totals and flagged (`*` + a ⚠️ note), so missing prices are visible.
- **Scope:** cost covers metered per-token engines (Claude, Gemini, o4-mini). It does
  **not** cover Copilot code review, which bills GitHub Actions minutes / AI credits
  from 2026-06-01 — a different unit. Cache-write, batch (−50%), fast-mode and
  server-tool surcharges are not modelled (records only carry input/cache-read/output).
- Claude rates are verified against [Anthropic's pricing](https://platform.claude.com/docs/en/docs/about-claude/pricing);
  non-Claude rows are best-effort and marked `VERIFY` in the table.

## Effective Tokens (ET)

A normalised cost comparator, kept alongside USD:

```
ET = m × (1.0 × input + 0.1 × cache_read + 4.0 × output)
```

`m` is **derived from the price table** (`m = input_price(model) ÷ input_price(haiku)`),
so it stays in sync with real prices:

| Model | Multiplier |
|---|---|
| haiku | 1× |
| sonnet | 3× |
| o4-mini, gemini-pro | 2× |
| gemini-flash | 0.5× |
| opus (4.5+) | 5× |

Output is weighted 4× and cache-read 0.1×, so ET tracks *cost*, not raw token count.
(ET and USD can rank workflows differently when output ratios differ — trust USD for
budgeting; ET is a quick comparator.)

## Delivery

| Channel | Cadence | Where |
|---|---|---|
| **Tracking issue comment** | Weekly (Mon 08:00 UTC) | A single pinned issue in `.github-private` labelled `token-report`; each run adds a comment. |
| **Step Summary** | Weekly + on every fleet-monitor run | Actions run summary of `token-report.yml` and `actions-fleet-monitor.yml`. |

## Usage

Runs automatically every Monday. To trigger manually:

```bash
gh workflow run token-report.yml \
  --repo petry-projects/.github-private \
  --field org=petry-projects \
  --field lookback_days=7
```

To generate the report locally (requires a token with org-wide `actions:read`):

```bash
ORG=petry-projects LOOKBACK_DAYS=7 GH_TOKEN="$(gh auth token)" \
  bash scripts/token_report.sh
```

## Architecture

| File | Role |
|---|---|
| `scripts/lib/model-pricing.tsv` | Single source of truth for prices — effective-dated rows. |
| `scripts/lib/model-pricing.sh` | `price_for` / `cost_usd` / `et_multiplier_for` (glob + date lookup). |
| `scripts/token_report.sh` | Org-wide collection (`main`/`collect_org_jsonl`) + pure rendering (`annotate_records`, `render_token_report`). |
| `tests/token_report.bats`, `tests/model_pricing.bats` | Unit tests for rendering and dated pricing. |
| `.github/workflows/token-report.yml` | Weekly cron → tracking-issue comment. |
| `.github/workflows/actions-fleet-monitor.yml` | Daily Step-Summary rollup (reuses the same script). |

## Environment variables (script)

| Variable | Description |
|---|---|
| `ORG` | Org to scan (default `petry-projects`). All non-archived repos discovered automatically. |
| `LOOKBACK_DAYS` | Rolling window of artifact history to include (default `7`). |
| `GH_TOKEN` | PAT with `actions:read` across the org — token-usage artifacts are per-repo. Uses `GH_PAT_WORKFLOWS` in CI. |
| `TOKEN_REPORT_OUT` | Optional path to also write the report to (used by the workflow to post the issue comment). |

## Known limitations

- **Artifact retention**: token-usage artifacts use GitHub's default retention. A
  lookback longer than the retention window will silently miss expired artifacts.
- **Cache tokens**: captured from real API usage for Claude/Gemini. Copilot exposes no
  usage, so copilot calls fall back to estimates with 0 cache. Records written before this
  capture landed have 0 cache (the old estimate path).
- **Per-repo artifact API**: one `actions/artifacts` listing per repo per run. For
  very large orgs this is linear in repo count.
