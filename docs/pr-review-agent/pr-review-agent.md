# PR Review Agent

A scheduled GitHub Action that reviews open PRs on don-petry's behalf.
Runs hourly, classifies risk, auto-approves low/medium-risk PRs that pass all
quality gates, and escalates high-risk or gated PRs for human review.

Supports two LLM engines via the `REVIEW_ENGINE` repo variable: **Claude** (default)
and **Copilot**.

## How it works

1. **Cron** — `.github/workflows/pr-review.yml` runs at `:07` every hour
   (and on `workflow_dispatch`).
1a. **@mention** — comment `@donpetry-bot` on any PR to trigger an immediate
    review, bypassing the hourly schedule. See [Mention-triggered reviews](#mention-triggered-reviews).
2. **Enumerate** — `scripts/list-prs.sh` queries GitHub for open PRs across
   every repo the PAT can see (the bot's personal account plus `TARGET_ORG`),
   **excluding PRs authored by `BOT_USER`** (the workflow's authenticated
   identity, default `donpetry-bot`). GitHub's GraphQL API rejects
   self-approval unconditionally, so self-authored PRs are unreviewable and
   would otherwise starve the queue. Output: one URL per line.
3. **Per-PR review** — `scripts/review-one-pr.sh` runs a cascading review
   where each tier only fires if the previous one flagged concerns:

   ```
   Tier 1: Triage (~15s, no tools, pre-fetched context)
     └─ clean? → single confirmation → approve + auto-merge
     └─ concerns? ↓
   Tier 2: Deep review + Rubber duck (~2 min, parallel, cross-engine)
     └─ synthesize verdicts from both engines
     └─ clean? → approve + auto-merge
     └─ HIGH risk? ↓
   Tier 3: Security audit (~3 min, full agentic)
     └─ final decision → approve or escalate
   ```

   ### Cross-engine adversarial review (Rubber Duck)

   At tier 2, two reviewers analyze the PR **in parallel** using different
   model families. The primary engine runs the deep review; the **opposite**
   engine runs an adversarial "rubber duck" review. A synthesis step merges
   both verdicts before deciding whether to approve or escalate.

   This approach is inspired by [GitHub Copilot CLI's rubber duck feature](https://github.blog/ai-and-ml/github-copilot/github-copilot-cli-combines-model-families-for-a-second-opinion/),
   which shows cross-model review closes ~75% of the performance gap between
   model tiers. Different model families have different blind spots — running
   both catches issues that either alone would miss.

   The rubber duck is **always the opposite engine**: if `REVIEW_ENGINE=claude`,
   the duck is Copilot (GPT-5.4), and vice versa. No extra configuration needed.

   **Graceful degradation:** if the rubber duck fails (missing credentials,
   CLI not installed, timeout), the cascade continues with the primary deep
   review only. The duck is additive, never blocking.

   ### Engine model mapping

   | Tier | Claude primary | Copilot primary |
   |---|---|---|
   | Triage | Haiku 4.5 | GPT-5-mini |
   | Deep review | Sonnet 4.6 | GPT-5.2 |
   | Rubber duck | GPT-5.4 (cross) | Sonnet 4.6 (cross) |
   | Synthesis | Sonnet 4.6 | GPT-5.2 |
   | Security audit | Opus 4.6 | GPT-5.4 |
   | Action / single review | Sonnet 4.6 / Opus 4.6 | GPT-5.2 / GPT-5.4 |

   **Cost profile:**
   - ~80% of PRs: triage + single confirm (2 calls, ~30s)
   - ~15% of PRs: + deep + duck + synthesis (5 calls, ~3 min)
   - ~5% of PRs: + security audit (6 calls, ~6 min)

4. **Post-review actions** — after the review is posted, the action tier takes
   additional actions depending on the decision:
   - **If approved:** removes the `needs-human-review` label if present, and
     rebases the branch if it's behind base. The PR remains open for manual merge
     by the author or maintainers.
   - **If escalated + AI delegation enabled:** posts a follow-up comment
     with specific fix instructions. An AI agent watches for these comments,
     pushes fixes → next cron tick detects new SHA → cascade re-reviews →
     approve when clean. This creates an autonomous fix loop.
   - **If escalated + no delegation (or max cycles reached):** labels
     `needs-human-review` and re-requests don-petry as reviewer.
   - **Cycle guard:** before running the cascade, `scripts/review-one-pr.sh`
     counts *non-converging* review cycles on the PR: non-approval review
     markers posted since the most recent reset event (the latest approval
     marker or the latest escalation comment). If the count is
     `>= MAX_REVIEW_CYCLES` (default 3), the cascade is skipped entirely;
     the script posts a single human-escalation comment marked
     `<!-- pr-review-agent escalation -->`, adds `needs-human-review`, and
     re-requests don-petry. Subsequent runs no-op while the escalation marker
     AND the `needs-human-review` label are both present. This prevents
     infinite review loops on PRs that aren't converging, without punishing
     PRs that converge (approve) and then legitimately evolve (issue #467).
     Re-engagement paths: remove the `needs-human-review` label (cascade
     resumes on the next run with a fresh cycle budget), or mention the bot —
     mention-triggered runs (`FORCE_REVIEW=true`) bypass the escalation pause
     and the cap, and drop the label so the cascade stays engaged.

5. **Idempotency + iterative review cycles** — every posted review starts with
   an HTML marker on line 1:

   ```
   <!-- pr-review-agent v1 sha=<full-commit-sha> decision=... risk=... -->
   ```

   Before invoking the cascade, `scripts/review-one-pr.sh` fetches the PR's
   current head SHA and scans existing reviews/comments for the marker. If a
   marker matching the current head SHA exists, the script skips the PR
   without spending tokens. If a marker exists for an older SHA, the script
   knows the PR has new commits since the last review and runs the cascade
   again — handling iterative review cycles cleanly.

## Interaction contract

pr-review pairs a **Class 1 event fast-path** (the `pr-review-trigger.yml` caller stub) with a
**Class 2 backstop timer** (`pr-review-sweep.yml`) under the
[agentic interaction model](../agentic-interaction-model.md) (the normative standard). Its
triggers, timers, emits, and stop markers are declared as machine-readable, CI-verified
contracts rather than prose:

- **Runtime lens** — [`interaction-contracts/pr-review.yml`](../../interaction-contracts/pr-review.yml)
  (the deployed trigger/sweep `on:` blocks, the backstop timer's `stop_condition` +
  `event_fast_path`, emits, and budget).
- **Role lens** — [`personas/pr-review/interaction.yml`](../../personas/pr-review/interaction.yml)
  (the persona-manifest view of the same pattern).

When the trigger or sweep workflow's `on:` block changes, update those contracts and the
standard's §4 classification table in the same change.

## Setup

### Reviewer identity

The agent posts PR reviews and approvals using the `DON_PETRY_BOT_GH_PAT` secret. This
token **must belong to a different GitHub account than the PR author** —
GitHub blocks self-approval (a user cannot approve their own PR). If the
same account both opens PRs (via Claude automation) and tries to approve
them, every approval will silently fail.

The recommended pattern: create a dedicated **reviewer bot account**
(e.g. `donpetry-bot`) whose token is stored as `DON_PETRY_BOT_GH_PAT`. PRs are
authored by `don-petry`; the bot approves them.

### 1. Create the reviewer bot account

1. Sign out of GitHub (or use a private browser window).
2. Go to <https://github.com/signup> and create a new account.
   - **Username:** e.g. `donpetry-bot`
   - **Email:** a dedicated alias works well (e.g. `you+donpetry-bot@gmail.com`)
3. Verify the email address.
4. Sign back in as `don-petry`.
5. Go to **github.com/organizations/petry-projects/settings/members** →
   **Invite member** → enter `donpetry-bot` → Role: **Member**.
6. Accept the invite from the bot account.

### 2. Create a PAT for the bot (classic or fine-grained)

You can use either a **classic** or **fine-grained** PAT. Classic PATs are the
safe default — see [bot-setup.md](bot-setup.md) for a known failure with
fine-grained tokens in some org configurations (`addPullRequestReview` blocked
at the org policy layer). Fine-grained tokens work when your org permits them
and follow the principle of least privilege.

#### Option A: Fine-grained PAT (recommended)

1. Sign in as the bot account (e.g. `donpetry-bot`) — sign out of `don-petry`
   first, or use a private window. The PAT must be created **from the bot's
   account**, not yours.
2. Go to **Settings → Developer settings → Personal access tokens →
   Fine-grained tokens** → **Generate new token**.
3. Settings:
   - **Token name:** `pr-review-agent`
   - **Expiration:** 90 days (set a calendar reminder to rotate — fine-grained PATs do not auto-rotate)
   - **Resource owner:** select your organization (e.g. `petry-projects`)
   - **Repository access:** All repositories (or specific repos if preferred)
   - **Repository permissions:**
     - `contents:read` — read files and diffs for analysis
     - `pull_requests:write` — post reviews and comments
   - **Organization permissions:**
     - `members:read` — (optional) read org members for code owner routing at escalation time
4. Generate and copy the token immediately.
5. Sign back in as `don-petry` and store the token in the agent repo's secret
   (the secret name is `DON_PETRY_BOT_GH_PAT` in `petry-projects/.github-private`).

#### Option B: Classic PAT (legacy)

If you prefer classic PATs or need broader scopes:

1. Sign in as the bot account, go to **Settings → Developer settings →
   Personal access tokens → Tokens (classic)** → **Generate new token (classic)**.
2. Settings:
   - **Note:** `pr-review-agent`
   - **Expiration:** 1 year
   - **Scopes:** ✅ `repo`, ✅ `workflow`, ✅ `read:org`
3. Generate and store as `DON_PETRY_BOT_GH_PAT` (same as above).

After saving either token type, trigger a workflow run and confirm the
`gh auth status` output reports the bot's login (not yours) and lists the
required scopes.

> **Branch protection / rulesets:** add `donpetry-bot` as an allowed
> approver on each protected repo. In the repo ruleset or branch protection
> settings, ensure the bot is not excluded from the reviewer pool.

### 3. Add your LLM engine auth token

#### Claude engine (default)

Routes the agent's usage through your Claude Max plan. Generate the token:

```
claude setup-token
```

Store as a repo secret:

```
gh secret set CLAUDE_CODE_OAUTH_TOKEN --repo petry-projects/.github-private
```

#### Copilot engine

Create a GitHub PAT with Copilot scope. Store as a repo secret:

```
gh secret set COPILOT_GITHUB_TOKEN --repo petry-projects/.github-private
```

### 4. Choose your engine

```
# Use Copilot (GPT models):
gh variable set REVIEW_ENGINE --body copilot --repo petry-projects/.github-private

# Use Claude (default — no variable needed, or set explicitly):
gh variable set REVIEW_ENGINE --body claude --repo petry-projects/.github-private
```

### 5. Test with a dry run

```
gh workflow run pr-review.yml --repo petry-projects/.github-private -f dry_run=true
gh run watch --repo petry-projects/.github-private
```

To review a single PR ad-hoc:

```
gh workflow run pr-review.yml --repo petry-projects/.github-private \
  -f pr_url=https://github.com/owner/repo/pull/123 \
  -f dry_run=true
```

## Going live

The cron defaults to **dry-run mode** — it gathers context and prints decisions
but never posts reviews, comments, labels, or reviewer requests. To enable
live mode:

```
gh variable set LIVE_MODE --body true --repo petry-projects/.github-private
```

To go back to dry-run:

```
gh variable delete LIVE_MODE --repo petry-projects/.github-private
```

A specific run can always be forced either way via the `dry_run` workflow input:

```
gh workflow run pr-review.yml --repo petry-projects/.github-private -f dry_run=false
```

## Tuning

- **Review engine** — `REVIEW_ENGINE` repo variable: `claude` (default) or
  `copilot`. Controls which CLI and model family is used.
- **Risk rules** — edit `prompts/shared.md` (taxonomy), or the per-tier
  prompts (`prompts/deep-review.md`, `prompts/security-audit.md`).
- **Cron frequency** — change the `cron:` line in the workflow file.
- **Scope** — edit `scripts/list-prs.sh` to add/remove queries (e.g. to include
  PRs from a specific org, or to exclude certain repos).
- **AI delegation** — set `DELEGATION_ORGS` to a comma-separated list of
  GitHub orgs where AI-assisted fix delegation is enabled:
  `gh variable set DELEGATION_ORGS --body "petry-projects,don-petry" --repo petry-projects/.github-private`
- **Max review cycles** — how many times the agent delegates to AI before
  escalating to human (default 3):
  `gh variable set MAX_REVIEW_CYCLES --body 5 --repo petry-projects/.github-private`
- **Models** — change model IDs in `scripts/engine.sh`. The cascade tiers
  map to: triage → deep → audit → action.
- **Max PRs per run** — defaults to 10 per cron tick to stay within the 60-min
  job timeout. Override:
  `gh variable set MAX_PRS --body 15 --repo petry-projects/.github-private`
- **MCP review (opt-in, off by default)** — the deep and rubber-duck tiers can
  load [MCP](https://modelcontextprotocol.io) servers via `REVIEW_MCP_CONFIG`
  (path to an MCP-servers JSON config) and `REVIEW_MCP_ALLOWED_TOOLS`
  (comma-separated MCP tool names merged into `--allowed-tools`). The triage
  tier never receives MCP.

  Enablement is **committed-file-only** — no edit to the org-template-synced
  `pr-review.yml` is needed. `engine.sh` resolves `REVIEW_MCP_CONFIG` as:
  1. an explicit `REVIEW_MCP_CONFIG` env value (honored as-is, takes precedence), else
  2. the conventional committed path `.github/review-mcp.json` — but only if that
     file exists. If neither is present, MCP stays off and behavior is unchanged.

  To turn it on, copy the no-auth Context7 sample into place and allow its tools:
  ```bash
  cp .github/review-mcp.json.sample .github/review-mcp.json
  gh variable set REVIEW_MCP_ALLOWED_TOOLS --body 'mcp__context7__*' --repo petry-projects/.github-private
  ```
  `.github/review-mcp.json.sample` is documentation-only and inert — the scripts
  only auto-discover the suffix-less `.github/review-mcp.json`. Context7 needs no
  auth; an MCP server that requires a secret would need that secret wired into the
  workflow's `env:` block as a documented per-repo exception (see AGENTS.md).

## Mention-triggered reviews

Comment `@donpetry-bot` on any PR to start an immediate, on-demand review
without waiting for the next scheduled run. The bot posts an acknowledgement
within seconds and the full cascade result appears in a few minutes.

**How it flows:**

```
PR comment "@donpetry-bot please review"
  → petry-projects/.github: pr-review-mention.yml (listens org-wide)
      → validates commenter trust (OWNER/MEMBER/COLLABORATOR only)
      → posts ack comment "I'm on it..."
      → gh workflow run pr-review.yml --field pr_url=<url> --field force_review=true
          → petry-projects/.github-private: pr-review.yml (per-PR concurrency slot)
              → scripts/review-one-pr.sh (FORCE_REVIEW=true bypasses idempotency)
                  → cascade as normal → posts review
```

**Key behaviors vs. scheduled runs:**
- `force_review=true` skips the "already reviewed at this SHA" no-op, so you
  always get a fresh analysis even if the head commit hasn't changed.
- Each mention-triggered run uses its own concurrency group (`pr-review-mention-<url>`)
  so it doesn't queue behind hourly batch runs or other mentions.
- Commenter trust is enforced — external contributors cannot trigger reviews.

**Setup (one-time):**

1. Copy [`templates/mention-listener.yml`](templates/mention-listener.yml) to
   `petry-projects/.github` as `.github/workflows/pr-review-mention.yml`.

2. Ensure the `GH_PAT_WORKFLOWS` org-level secret is available to
   `petry-projects/.github`. This secret is already present in the org; no
   additional secret setup is required. The workflow template references
   `GH_PAT_WORKFLOWS` throughout — use the same PAT created above in
   [step 2](#2-create-a-pat-for-the-bot-classic-or-fine-grained) if you need to
   rotate or recreate it.

3. Ensure `donpetry-bot` has at least **Read** collaborator access on
   `petry-projects/.github-private`.

## Architecture

```
scripts/engine.sh         ← LLM abstraction (claude/copilot dispatch)
scripts/review-one-pr.sh  ← Cascade orchestrator (sources engine.sh)
scripts/list-prs.sh       ← PR enumeration

prompts/triage.md         ← Tier 1: fast risk triage (no tools)
prompts/deep-review.md    ← Tier 2: thorough review (agentic)
prompts/security-audit.md ← Tier 3: paranoid security check (agentic)
prompts/single-review.md  ← Fast path: small/incremental/triage-approved
prompts/cascade-action.md ← Post-review: post, merge, delegate
prompts/shared.md         ← Shared risk taxonomy and decision gates
```

## Cost

Uses the configured engine's billing:
- **Claude:** Max plan via OAuth token — no per-token API billing.
- **Copilot:** Included in GitHub Copilot subscription.

GitHub Actions cost is ~720 runs/month (hourly × 30 days). Runs with zero
candidate PRs finish in ~10s. Each PR reviewed costs ~2-5 min of runner time
depending on how many cascade tiers fire.
