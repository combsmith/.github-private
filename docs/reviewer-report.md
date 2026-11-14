# Third-Party Reviewer Scorecard — Weekly Report

Org-wide, **deterministic** visibility into the agentic third-party code reviewers that
participate in PR review across `combsmith` — GitHub Copilot, Gemini Code Assist,
Codex, CodeRabbit, SonarCloud, Qodo Merge, CodeAnt, Graphite, and cubic. Every figure is computed with `jq`/`awk` from GitHub's
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
reviewer-source registry (`scripts/lib/reviewer-sources.tsv`, [#1425](https://github.com/combsmith/.github-private/issues/1425)),
which the advisory-review gate and this report both project from, so the report can never
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
| cubic | `cubic-dev-ai` |

The org's own Claude reviewer (`donpetry-bot`) is intentionally **out of scope** here — its
cost lives in the [Token Cost Observatory](./token-report.md); this report is about the
external vendors.

## Data source: one batched GraphQL query per repo

For each repo we paginate PRs newest-first and pull, in a **single round-trip per page**,
each PR's `reviews`, `reviewThreads` (with `isResolved` / `isOutdated`, reaction
counts, and each comment's path, lines and parent review id), and issue `comments`. Pagination stops as soon as a page's PRs predate the
lookback window (PRs are ordered by `UPDATED_AT` descending), so we never walk a repo's
entire history. This is far fewer API calls than per-PR REST fetches.

Pages are deliberately **light** — `PR_PAGE_SIZE` PRs per page (default 10) with bounded
nested connections — because a heavy page trips GitHub's GraphQL resource limit, which
returns an HTTP-200 body carrying an `errors` array and **null `data`**. The old code read
that as "no PRs" and silently dropped the whole repo (the ~8× Graphite undercount, [#1908](https://github.com/combsmith/.github-private/issues/1908)).
A failed page is now **retried with a halved page size and backoff** (`PR_FETCH_MAX_ATTEMPTS`,
default 4); a repo that still fails is recorded as a `{kind:"collect_error"}` record and
surfaced prominently in the report — never a silent drop.

### Check-run reviews (Graphite)

Some reviewers report a review **only as a check run**, not as a PR review or comment.
Graphite's "Graphite / AI Reviews" check run is the canonical case: a clean pass posts the
check run with **zero** PR comments, so the old scorecard read every clean pass as *No
response* and undercounted its engagement. Which bots report this way — and the exact
check-run name — is **data-driven** in the reviewer-source registry
(`scripts/lib/reviewer-sources.tsv`, `check_run_name` column); nothing is hard-coded to
`graphite-app`. For each in-window PR we make a **separate, lightweight REST call** for the
head commit's check runs (`GET /repos/{o}/{r}/commits/{sha}/check-runs`) so the heavy PR
page query stays under the resource limit. Every **completed** matched check run is a bot
message and is classified like any other message (see [Message classes](#message-classes)): its
output summary is matched against the bot's patterns, so Graphite's `neutral` run with the summary
"AI review skipped: hourly limit reached" is `refused`. A run with a failed conclusion (`failure`,
`cancelled`, `timed_out`, `action_required`, `stale`, `startup_failure`) is always `status`, even if
its summary mentions the review. A queued or in-progress run has no result yet and is not a message.

Each PR node is normalized (pure `jq`) into two record kinds:

- `{kind:"pr", …}` — one per PR (the eligible-PR **denominator**).
- `{kind:"bot_pr", …}` — one per tracked bot that left at least one message on the PR. It
  carries the per-class message counts (`classes`), `real_responses` (finding + clean
  messages), `refusals`, latency to the first finding or clean message, verdict counts, the
  threads the bot opened and how many are resolved, `findings_raised` with its two parts
  `findings_threads` and `findings_body`, reactions, and up to 3
  truncated `unclassified_samples`. A check-run clean pass adds **0** to the review-event
  count but makes the PR count as reviewed.

Three diagnostic record kinds keep collection gaps visible (never silent, [#1908](https://github.com/combsmith/.github-private/issues/1908)):

- `{kind:"collect_error", repo, reason}` — a repo that could not be collected after retries.
- `{kind:"truncation", repo, pr, connection}` — a nested connection (≥50), a review thread's
  comments (≥20), or the per-repo PR pagination (`MAX_PR_PAGES`) that hit its fetch cap, so a
  bot's reviews/comments on that PR — or a repo's later in-window PRs — may be undercounted.
- `{kind:"check_run_error", repo, pr}` — a per-PR check-run REST fetch that failed, so a
  check-run reporter's clean pass on that PR may be missed and miscounted as *No response*.

All are rendered in a **Collection health** section at the top of the report. Human authors
and untracked bots are dropped at normalization time.

## Message classes

Every bot message (a PR review body, an inline review-thread comment, a top-level PR comment,
or a completed check run) gets **exactly one** class ([#2504](https://github.com/combsmith/.github-private/issues/2504)):

| Class | Meaning | Example |
|---|---|---|
| `finding` | The bot raised at least one problem. | An inline comment; "Actionable comments posted: 2"; "Quality Gate failed". |
| `clean` | The bot reviewed and found nothing. | "Didn't find any major issues"; "Quality Gate passed"; a Graphite check run that left 0 comments. |
| `refused` | The bot declined because of quota, rate limit, trial or plan. | "You have reached your daily quota limit"; "trial has ended"; Graphite's "hourly limit reached". |
| `skipped` | The bot did not review because of its own or the repo's configuration. | CodeRabbit "Review skipped" / "Auto reviews are disabled". |
| `status` | Progress, summary, marketing or bookkeeping text with no verdict. | "Codex Review Summary"; "Thanks for using CodeAnt"; a bot's reply inside a thread; a failed check run. |
| `unclassified` | Nothing matched. | Any message shape no pattern knows yet. |

The class is decided in this order, and the first hit wins:

1. A check run with a failed conclusion is `status`.
2. The bot's own rows in `scripts/lib/reviewer-message-classes.tsv`, top to bottom. A row of
   kind `any` reaches an inline comment only when its class is `finding` or `clean`
   ([#2527](https://github.com/combsmith/.github-private/issues/2527)). A broad `status`,
   `skipped` or `refused` phrase ("Review Status", "review in progress", "review is skipped")
   quoted inside a real inline finding must not drop it from threads and findings. A row of
   kind `inline` still applies whatever its class.
3. The shared refusal fallback, `ADVISORY_RATE_LIMIT_RE` from `scripts/lib/advisory-review-gate.sh`
   plus its author-scoped cubic clause, gives `refused`. It is never applied to inline comments,
   because a finding that talks about a rate limit is still a finding.
4. Structural defaults:
   - the first comment of a review thread is a `finding`, and a later comment by the same bot (a reply) is `status`;
   - a `CHANGES_REQUESTED` review is a `finding` and an `APPROVED` one is `clean`;
   - when no earlier pattern matches, a check run that succeeded, or whose summary says the review ran, is `clean`;
   - a check run skipped with a decline reason is `refused`, one skipped otherwise is `skipped`, and one with an empty summary is `status`.
5. Otherwise `unclassified`.

A PR counts as **reviewed** by a bot only if the bot left at least one `finding` or `clean`
message on it. A PR with only status messages, or only unclassified ones, never counts as
reviewed. The report lists up to 3 truncated sample bodies per bot for `unclassified` messages,
so a new message shape shows up and can be given a pattern. Samples have URLs and backticks
removed, are cut to 100 characters, and are printed inside code spans so an `@mention` in a bot
body never notifies anyone. They are not stored in the snapshot artifact.

Patterns match GraphQL `bodyText`, the plain-text rendering of the body with HTML comments and
markdown markup removed. That is why the gate's own patterns (`info_status_pattern`, the finding-section
pattern), which match the markdown `body`, are not reused as they are.

### Adding patterns for a new bot

1. Register the bot in `scripts/lib/reviewer-sources.tsv` first. Every login in the sidecar
   must be a registered source (`tests/reviewer_report.bats` checks it).
2. Add rows to `scripts/lib/reviewer-message-classes.tsv`, one pattern per row:
   `login<TAB>class<TAB>kind<TAB>pattern`.
   - `class` is `finding`, `clean`, `refused`, `skipped` or `status`.
   - `kind` is `any`, `review`, `inline`, `issue` or `check_run`. An `any` row of class `status`,
     `skipped` or `refused` never reaches inline comments; write a `kind: inline` row if you
     really mean one.
   - `pattern` is a jq (Oniguruma) regex, matched case-insensitively against the message's `bodyText`, or against a check run's output summary.
3. Order matters: the first matching row wins. Put narrow rows above broad ones. For example, put
   a refusal row above a `status` row that matches the summary comment the refusal sits in, and
   a finding marker above a `clean` row.
4. Add a fixture for each new message shape to `tests/fixtures/reviewer_message_classes.json`
   (`bot`, `kind`, `body`, the expected class in `expect`, and `state` / `conclusion` where they
   apply). Include at least one real finding and one clean pass. Run `bats tests/reviewer_report.bats`.
5. Watch the **Unclassified messages** section of the next reports and add rows for what shows up.

The sidecar is **scorecard only**. Neither the advisory approval gate nor the maintainer-comment
gate reads it, so a row here never changes what blocks or clears a merge.

## Metrics

Everything is deterministic.

### Scorecard (headline)

Each eligible PR lands in exactly one bucket per bot, checked in this order: With findings,
Clean, Refused, Skipped, No response. So the five PR columns sum to **Total PRs**.

| Column | Definition |
|---|---|
| **Total PRs** | Review-eligible (non-draft) PRs active in the window; the denominator each row is measured against. |
| **With findings** | PRs where the bot left at least one `finding` message. |
| **Clean** | PRs where the bot left a `clean` message and no `finding`. |
| **Refused** | PRs with no finding or clean message and at least one `refused` message. |
| **Skipped** | PRs with no finding, clean or refused message and at least one `skipped` message. |
| **No response** | Every other eligible PR: the bot never appeared, or left only `status` or `unclassified` messages. A queued check run leaves the PR here too. |
| **Findings raised** | Review threads the bot opened with a finding, plus the findings written in its `finding` review, comment or check-run bodies. See [Body findings](#body-findings) for how a body is counted. The Details section shows the two parts separately. |
| **Resolved %** | Threads the bot opened that are resolved, out of all threads it opened (`n/a` when it opened none). |
| **Latency p50 / p95** | Time from PR creation to the bot's first `finding` or `clean` message. Refusals and status notices never count, so they don't pollute the percentiles. Targets the "review arrived after auto-approval" failure mode (PR #453). |

### Details

The event counts that used to head the table, plus the reactions the snapshot always
collected, are in a **Details** section:

| Column | Definition |
|---|---|
| **Reviews** | Formal reviews the bot submitted, **each occurrence** (GitHub creates a new review each time a bot re-reviews after a commit, so a PR reviewed across 5 commits contributes 5). Refusals, skips and status notices are left out. A bot that posts no formal review but delivers its verdict as a top-level comment (SonarCloud) has its `finding` / `clean` comments counted instead. Its status and quota comments are never counted. |
| **✅ / 🔄** | Of those reviews, how many carried state APPROVED / CHANGES_REQUESTED. |
| **Refusal events** | Every `refused` message, each occurrence. |
| **👍 / 👎** | Reactions on the bot's inline comments. |
| **Status messages / Unclassified messages** | Message counts. Neither ever makes a PR count as reviewed. |
| **Findings: threads / bodies** | The two parts of **Findings raised**: review threads the bot opened with a finding, and findings counted from its bodies. |

### Body findings

Some bots write findings in a review body that never become review threads
([#2527](https://github.com/combsmith/.github-private/issues/2527)). Each `finding` body that is
not an inline comment is counted by its bot's rule:

| Bot | Body findings counted |
|---|---|
| **coderabbitai** | The counts in its **Outside diff range comments** and **Nitpick comments** section headers, whether or not it opened threads on the PR. `bodyText` carries both header forms, `Outside diff range comments (2)` and `Nitpick comments: 2`. The unnumbered repeats in its "Prompt to fix all issues" block, and its "Duplicate comments" and "Additional comments" sections, add nothing. |
| **chatgpt-codex-connector** | Each code location the body points at, read from `bodyText` as the permalink (`…/blob/<sha>/<path>#L<a>-L<b>`) or as the snippet GitHub renders from it (`<repo>/<path> Lines <a> to <b> in <sha>`). The snippet's leading repo name is dropped, so both forms give a repository-relative path. A location counts unless an inline comment **from the same review** has exactly that path and an overlapping line, on either the current or the original diff. |
| Every other bot | Nothing beyond the fallback below. |

Fallback, for every bot: a `finding` body for which the rule above found nothing counts **once**,
and only on a PR where the bot opened no thread. On a PR with threads, such a body is the summary
of those threads ("Actionable comments posted: 2", "Here are some automated review suggestions").

In the 80 Codex reviews sampled across five repos when this rule was written, every body was
boilerplate beside its inline comments, so the Codex rule usually adds nothing. It is there for the
body-only suggestions Codex posts when it cannot attach a comment to the diff.

**Coverage overlap** counts non-draft PRs *reviewed* (finding or clean) by ≥2 bots. It is a redundancy
versus specialization signal.

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

Deltas cover the headline columns With findings, Clean, Refused, Skipped, No response and
Findings raised, plus Resolved % in percentage points. They also cover Reviews and Refusal events
in the details section. Snapshots carry `schema_version: 3`. A prior snapshot without
`schema_version` 2 or later (written before [#2504](https://github.com/combsmith/.github-private/issues/2504))
shows **no** headline delta, because its refused and no-response counts were made under the old
rules. Findings raised needs a `schema_version: 3` prior
([#2527](https://github.com/combsmith/.github-private/issues/2527)): before that, CodeRabbit and
Codex body findings beside their threads were not counted, so it shows no delta against a v2 week. The details
deltas still compare. So in the first week after the change, the Reviews delta also reflects that
status and quota comments are no longer counted.

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
| `scripts/lib/reviewer-sources.tsv` + `scripts/lib/reviewer-sources.sh` | The reviewer-source registry ([#1425](https://github.com/combsmith/.github-private/issues/1425)) + its sourced lookup helpers — the single source of truth for bot logins and the `check_run_name` map, projected by the gate and this report. |
| `scripts/lib/reviewer-message-classes.tsv` | Scorecard-only per-bot message-class patterns ([#2504](https://github.com/combsmith/.github-private/issues/2504)), read through `reviewer_sources_message_class_patterns`. Neither gate reads it. |
| `scripts/lib/advisory-review-gate.sh` | Advisory approval gate; rate-limit body patterns (reused, not forked). Its bot list is a registry projection. |
| `scripts/lib/comment-noise.sh` | Pure no-action agent-comment classifier + `cn_render_noise_section` (the noise metric). Unit-tested in `tests/comment_noise.bats`. |
| `scripts/reviewer_report.sh` | Org-wide GraphQL collection (`main` / `collect_org_reviews`) + pure normalization, aggregation, and rendering (`aggregate_snapshot`, `render_reviewer_report`). |
| `tests/reviewer_report.bats` + `tests/fixtures/reviewer_message_classes.json` | Unit tests for the pure normalize / aggregate / render path (no network), and one fixture per known message shape with its expected class. |
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
| `GH_OP_TIMEOUT` / `COLLECT_CONCURRENCY` / `MAX_PR_PAGES` | Per-call timeout (s), concurrent per-repo sweeps, and PR-page cap per repo (default 50). |
| `PR_PAGE_SIZE` / `PR_FETCH_MAX_ATTEMPTS` | PRs per GraphQL page (default 10 — kept light to stay under the resource limit) and maximum fetch attempts, including the initial request, before the repo is recorded as a `collect_error` (default 4). |

## Known limitations

- **GraphQL login form**: bot logins are matched without the `[bot]` suffix (the GraphQL
  form). If a bot ever posts under a different identity, add it to the shared registry.
- **Latency denominator**: PRs opened as drafts and later marked ready use creation time
  as the latency baseline in v1, which can overstate latency for long-draft PRs.
- **Per-repo pagination**: bounded by `MAX_PR_PAGES` (default 50) × `PR_PAGE_SIZE` (default
  10 PRs). A repo with more in-window PRs than that cap is truncated; when the cap stops a
  repo it emits a `{kind:"truncation", connection:"pullRequests"}` record surfaced in the
  **Collection health** section, so the scorecard is marked as a floor rather than silently
  dropping the overflow. The cap is generous for this org.
- **Nested-connection cap**: a PR's `reviews` / `comments` / `reviewThreads` are fetched up
  to 50 each, and each review thread's `comments` up to 20. A PR that exceeds 50 on any of
  those connections — or 20 comments on any single thread — emits a `{kind:"truncation"}`
  record (the per-thread case as `connection:"reviewThreads.comments"`) rendered in the
  **Collection health** section, so an undercount there is stated explicitly rather than
  hidden. The scorecard counts every node it did fetch, including bots beyond the 50th review.
- **Message wording**: classes come from body text. When a bot changes its wording, the new
  shape lands in `unclassified` (or a structural default) until a row is added to
  `scripts/lib/reviewer-message-classes.tsv`. The **Unclassified messages** section exists to
  make that visible. The check-run reporter set and check-run name live in
  `scripts/lib/reviewer-sources.tsv`.
