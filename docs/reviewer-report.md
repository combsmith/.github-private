# Third-Party Reviewer Scorecard — Weekly Report

Org-wide, **deterministic** visibility into the agentic third-party code reviewers that
participate in PR review across `combsmith` — GitHub Copilot, Gemini Code Assist,
Codex, CodeRabbit, SonarCloud, Qodo Merge, CodeAnt, and Graphite. Every figure is computed with `jq`/`awk` from GitHub's
own review data. **No LLM is involved** in this pipeline: a narrative / quality-scoring
layer is a deliberately separate, human-approved add-on (see [Roadmap](#roadmap-v2--llm-optional-human-approved)).

## The problem it solves

We rely on several external reviewer bots, but had no measured view of how each one
actually performs: Does it show up? How fast? Does it approve or ask for changes? Is it
being rate-limited? Are its comments acted on? Because the bots run as **org-level GitHub
Apps** that review PRs in every product repo, a single-repo view sees only a sliver. This
report sweeps **all non-archived repos** and rolls the answers into one weekly scorecard,
matching the delivery pattern of the [Token Cost Observatory](./token-report.md).

## Reviewers tracked

Identity comes from each bot's GraphQL App **login** — the single source of truth is the
advisory-review gate (`scripts/lib/advisory-review-gate.sh`), so this report can never
drift from the approval gate's notion of who these bots are.

| Reviewer | GraphQL login |
|---|---|
| GitHub Copilot | `copilot-pull-request-reviewer` |
| Gemini Code Assist | `gemini-code-assist` |
| Codex | `chatgpt-codex-connector` |
| CodeRabbit | `coderabbitai` |
| SonarCloud | `sonarqubecloud` |
| Qodo Merge | `qodo-code-review` |
| CodeAnt | `codeant-ai` |
| Graphite | `graphite-app` |

The org's own Claude reviewer (`donpetry-bot`) is intentionally **out of scope** here — its
cost lives in the [Token Cost Observatory](./token-report.md); this report is about the
external vendors.

## Data source: one batched GraphQL query per repo

For each repo we paginate PRs newest-first and pull, in a **single round-trip per page**,
each PR's `reviews`, `reviewThreads` (with `isResolved` / `isOutdated` and reaction
counts), and issue `comments`. Pagination stops as soon as a page's PRs predate the
lookback window (PRs are ordered by `UPDATED_AT` descending), so we never walk a repo's
entire history. This is far fewer API calls than per-PR REST fetches.

Each PR node is normalized (pure `jq`) into two record kinds:

- `{kind:"pr", …}` — one per PR (the eligible-PR **denominator**).
- `{kind:"bot_pr", …}` — one per tracked bot that touched the PR, carrying its
  `real_responses` / `refusals` split (a rate-limit-only touch is a refusal), latency to
  first real response, verdict counts, inline-comment count, thread resolution, and reactions.

Human authors and untracked bots are dropped at normalization time.

## Metrics

Everything is deterministic. **Reviews** and **Rate-limited** count *every event*, not
distinct PRs — GitHub creates a new review submission each time a bot re-reviews after a new
commit, so a PR reviewed across 5 commits contributes 5 reviews. This matters: on live data
CodeRabbit produced ~2× more review events than the distinct-PR count would suggest (up to 11
reviews on a single PR).

| Metric | Definition |
|---|---|
| **Total PRs** | Review-eligible (non-draft) PRs active in the window; the denominator each row is measured against. |
| **Reviews** | Count of reviews the bot submitted, **each occurrence** (multiple per PR from multiple commits all count). A bot that posts no formal review but delivers its verdict as a top-level comment (e.g. SonarCloud's quality-gate comment) has that comment counted as its review; bots that do submit formal reviews are unaffected, so their extra summary comments are never double-counted. Rate-limit notices are never counted. |
| **✅ / 🔄** | Of those reviews, how many carried state APPROVED / CHANGES_REQUESTED. |
| **Rate-limited** | Count of out-of-quota / rate-limit refusal events (detected by body text via the shared gate pattern), each occurrence. |
| **No response** | Eligible PRs the bot never engaged with at all — no review, comment, or refusal. |
| **Latency p50 / p95** | Seconds from PR creation to the bot's first **real** review (refusals excluded, so quota notices don't pollute the percentiles). Targets the "review arrived after auto-approval" failure mode (PR #453). |
| **Coverage overlap** | PRs reviewed by ≥2 bots — a redundancy vs specialization signal. |
| **Trend** | Week-over-week Δ (▲/▼) on Reviews and Rate-limited (event counts) vs last week's snapshot. Arrows are directional only. |

Per-PR bucket counts (`reviewed_prs` / `refused_prs` / `no_response_prs`, which partition the
eligible PRs), plus thread-resolution and reaction counts, are still computed and stored in the
snapshot for downstream use — they're just kept out of the headline table to keep it legible.

### Agent comment noise (our own automation)

Distinct from the third-party scorecard above, the report also measures the **no-action share of
our own automation's comments** — the net-new noise metric from [#1411](https://github.com/combsmith/.github-private/issues/1411).
This is deterministic (`scripts/lib/comment-noise.sh`), computed from the automation markers each
comment already carries — **no LLM**.

| Term | Definition |
|---|---|
| **Agent comment** | A PR comment or review whose body carries one of OUR automation markers: `<!-- pr-review-agent … -->`, `<!-- dev-lead… -->` (fix-reviews / fix-ci / noop-guard / issue / rate-limit), `<!-- persona:… -->`, or `<!-- dependency-advisory -->`. This is the **denominator**. Third-party reviewer bots are excluded (they emit no such marker and are scored in the table above). |
| **No-action comment** | An agent comment that asks nothing of a human. Two signals, both stable: known no-action **bodies** — "No actionable items found." (`post_no_changes`), "Engine ran but made no changes." (fix-ci), "No action required." (dependency advisory all-LOW) — and terminal no-op **marker fields** — `status=no-changes` (dev-lead) and `decision=approved` (a clean / repeat pr-review approval). |
| **Actionable comment** | Every other agent comment — an applied fix (`status=applied`), an escalated finding (`decision=escalated`), or a human-attention flag (no-op guard). |
| **Noise metric** | No-action comments as a **count** and as a **share** of all agent comments; **affected PRs** (distinct PRs with ≥1 no-action comment); and **no-action comments per PR** (denominator = PRs with any agent comment). |

- **Window / scope:** the same rolling `LOOKBACK_DAYS` window and the same all-non-archived-repo sweep as the scorecard; every PR active in the window (agent comments on draft PRs are vanishingly rare and not separately excluded).
- **PR denominator:** distinct PRs from `kind:"pr"` JSONL records — all active PRs in the window as set by the collection pass. **Affected PRs** = distinct PRs containing ≥1 no-action comment.
- **Attribution:** by marker, not by author — our agents commit/comment as human logins (`don-petry`, `donpetry-bot`), so identity is taken from the marker embedded in the body, never the login.
- **One code path:** the classifier is applied during the report's existing per-PR collection pass, so the pre-rollout **baseline** and every **after** measurement are produced by the same code (see [`docs/metrics-baseline.md`](./metrics-baseline.md)).

### Week-over-week deltas

The report has no external time-series store. Instead each run writes a compact per-bot
**snapshot** (`reviewer-report-state.json`) which the workflow uploads as an artifact; the
next run fetches the most recent prior snapshot via the GitHub API and diffs against it.
First-ever runs (or an expired artifact) simply omit the deltas — never an error.

## Known gaps (stated in every report)

- **Cost is not measured.** These reviewers are external SaaS GitHub Apps and emit no
  token-usage artifacts, so per-review `$` cost is not observable from our side. For our
  own Claude reviewer's spend, see the [Token Cost Observatory](./token-report.md).
- **Comment usefulness / false-positive rate** *for the third-party reviewers* requires judgment
  and is intentionally out of this deterministic report (see roadmap). The **Agent comment noise**
  metric above is different and deterministic — it scores only OUR automation's no-action share
  from the markers each comment already carries.
- **Latency baseline** is PR-creation time in v1; a refinement to last-human-push is
  tracked for v2.

## Roadmap (v2 — LLM-optional, human-approved)

The following need model judgment and are therefore **out of the deterministic pipeline**.
They would run only behind an explicit, human-triggered `workflow_dispatch` opt-in — never
unattended:

- Comment usefulness / true-positive vs noise scoring per reviewer.
- Semantic de-duplication of findings across reviewers (who found it first / uniquely).
- Finding categorization (bug / security / style / perf).
- A narrative "what changed and why it matters" synthesis with recommendations.

## Delivery

| Channel | Cadence | Where |
|---|---|---|
| **Tracking issue comment** | Weekly (Mon 09:53 UTC) | A single pinned issue in `.github-private` labelled `reviewer-report`; each run adds a comment. |
| **Step Summary** | Weekly | Actions run summary of `reviewer-report.yml`. |

Scheduled one hour after the token report (Mon 08:00 UTC) to avoid contending for the same
cross-repo token budget.

## Usage

Runs automatically every Monday. To trigger manually:

```bash
gh workflow run reviewer-report.yml \
  --repo combsmith/.github-private \
  --field org=combsmith \
  --field lookback_days=7
```

To generate the report locally (requires a token with org-wide repo read):

```bash
ORG=combsmith LOOKBACK_DAYS=7 GH_TOKEN="$(gh auth token)" \
  bash scripts/reviewer_report.sh
```

## Architecture

| File | Role |
|---|---|
| `scripts/lib/advisory-review-gate.sh` | Single source of truth for bot logins + rate-limit body patterns (reused, not forked). |
| `scripts/lib/comment-noise.sh` | Pure no-action agent-comment classifier + `cn_render_noise_section` (the noise metric). Unit-tested in `tests/comment_noise.bats`. |
| `scripts/reviewer_report.sh` | Org-wide GraphQL collection (`main` / `collect_org_reviews`) + pure normalization, aggregation, and rendering (`aggregate_snapshot`, `render_reviewer_report`). |
| `tests/reviewer_report.bats` | Unit tests for the pure normalize / aggregate / render path (no network). |
| `.github/workflows/reviewer-report.yml` | Weekly cron → snapshot upload + tracking-issue comment. |

## Environment variables (script)

| Variable | Description |
|---|---|
| `ORG` | Org to scan (default `combsmith`). All non-archived repos discovered automatically. |
| `LOOKBACK_DAYS` | Rolling window of PR activity to include (default `7`). |
| `GH_TOKEN` | PAT with repo read across the org — PRs + reviews are per-repo. Uses `GH_PAT_WORKFLOWS` in CI. |
| `REVIEWER_REPORT_OUT` | Optional path to also write the report to (used by the workflow to post the issue comment). |
| `REVIEWER_SNAPSHOT_OUT` | Optional path to write this week's per-bot snapshot (uploaded as the WoW artifact). |
| `REVIEWER_PREV_SNAPSHOT` | Optional path to last week's snapshot for deltas; `main()` fetches it automatically in CI. |
| `GH_OP_TIMEOUT` / `COLLECT_CONCURRENCY` / `MAX_PR_PAGES` | Per-call timeout (s), concurrent per-repo sweeps, and PR-page cap per repo. |

## Known limitations

- **GraphQL login form**: bot logins are matched without the `[bot]` suffix (the GraphQL
  form). If a bot ever posts under a different identity, add it to the shared registry.
- **Latency denominator**: PRs opened as drafts and later marked ready use creation time
  as the latency baseline in v1, which can overstate latency for long-draft PRs.
- **Per-repo pagination**: bounded by `MAX_PR_PAGES` (default 20 × 25 PRs). A repo with
  more in-window PRs than that cap would be truncated; the cap is generous for this org.
