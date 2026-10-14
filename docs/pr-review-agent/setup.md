# PR Review Agent Setup

This repository automates PR reviews for the `petry-projects` organization using Claude Code or GitHub Copilot.

## Quick Start

### Prerequisites
- GitHub organization: `petry-projects`
- Machine user account (e.g., `donpetry-bot`) added to org team in CODEOWNERS
- Secrets configured in the repository

### Repository Secrets Required

Store these in the repository settings (`Settings → Secrets and variables → Actions`):

| Secret | Description | Source |
|--------|-------------|--------|
| `CLAUDE_CODE_OAUTH_TOKEN` | Claude Code authentication token | `claude setup-token` |
| `DON_PETRY_BOT_GH_PAT` | Machine user classic PAT | Generated from `donpetry-bot` account settings — see [BOT_SETUP.md](BOT_SETUP.md) |
| `COPILOT_GITHUB_TOKEN` | GitHub Copilot token (optional, for fallback) | GitHub PAT with Copilot scope |

### Repository Variables (Optional)

| Variable | Default | Purpose |
|----------|---------|---------|
| `AI_ENGINES` | `claude,gemini,copilot` | Enabled engines in fallback order; the first is primary. See [engine configuration](../engine-configuration.md) |
| `REVIEW_ENGINE` | Unset | Legacy primary override (`claude`, `gemini` or `copilot`); leave unset to let `AI_ENGINES` decide |
| `AI_MODELS_CLAUDE` / `AI_MODELS_GEMINI` / `AI_MODELS_COPILOT` | Built-in lists | Each provider's model list, e.g. `deep=claude-opus-5-5,claude-opus-4-8`. See [engine configuration](../engine-configuration.md#model-lists-ai_models_) |
| `LIVE_MODE` | `false` | If `true`, reviews are posted live; if `false`, dry-run only |
| `DELEGATION_ORGS` | Empty | Comma-separated orgs where AI can auto-fix: `petry-projects,don-petry` |
| `MAX_REVIEW_CYCLES` | `3` | Max review iterations before escalating to human |
| `MAX_PRS` | `10` | Max reviews posted per scheduled run |
| `CANDIDATE_LIMIT` | `100` | Max candidates scanned per run |

## How It Works

### PR Enumeration
The agent reviews open PRs across every repo the PAT can see — the bot's
personal account (`gh repo list "$BOT_USER"`) and `TARGET_ORG` — meeting
these criteria:
- Open and not a draft
- Author is **not** `BOT_USER` (the bot can't approve its own PRs)
- Passing CI on org-repo searches (`--checks success`); per-PR re-checked in
  `review-one-pr.sh` as a second layer

See `scripts/list-prs.sh` for enumeration logic.

### Review Pipeline
Cascading: each tier only fires if the previous one flagged concerns.

1. **Tier 1 — Triage** (~15s, no tools). Clean → single confirmation → approve.
2. **Tier 2 — Deep review + Rubber duck** (~2 min, parallel cross-engine).
   Synthesis combines both verdicts; HIGH risk → tier 3.
3. **Tier 3 — Security audit** (~3 min, full agentic). Final approve/escalate.

See `prompts/` directory for review prompts and [AGENT.md](AGENT.md) for the
full design.

### Approval & Auto-Merge
When the agent approves a PR:
1. Posts an approval review via GitHub API
2. Rebases the branch if behind base (best-effort, retried up to 3×)
3. Enables auto-merge with squash strategy
4. Removes the `needs-human-review` label
5. Dismisses prior agent reviews and collapses prior agent comments

### Escalation
At cycle cap or `escalate` verdict without AI delegation,
`scripts/request-codeowners-review.sh` reads `CODEOWNERS` in the PR's repo
and requests review from every `@user` / `@org/team` mention. No reviewer is
hardcoded.

## Running Manually

### Dry-run (test without posting)
```bash
gh workflow run pr-review.yml \
  --repo petry-projects/.github-private \
  -f dry_run=true
```

### Review a specific PR
```bash
gh workflow run pr-review.yml \
  --repo petry-projects/.github-private \
  -f pr_url=https://github.com/petry-projects/<repo>/pull/<n> \
  -f dry_run=false
```

Combine with `-f force_review=true` to re-review a PR whose head SHA was
already reviewed (used by the `@mention` listener).

### Repair stuck approvals
If older PRs have agent comments but no approval reviews (legacy bug
artefact), use:
```bash
gh workflow run repair-pr-approvals.yml \
  --repo petry-projects/.github-private \
  -f dry_run=true
```

Then apply fixes with `dry_run=false`.

## Scheduled Runs

The `pr-review.yml` workflow runs hourly at `:07` to avoid the top-of-hour cron stampede.

To check recent runs:
```bash
gh run list --repo petry-projects/.github-private -w pr-review.yml -L 5
```

## Troubleshooting

### `failed to create review: GraphQL: Resource not accessible by personal access token (addPullRequestReview)`
- The `DON_PETRY_BOT_GH_PAT` secret is holding a **fine-grained** PAT. Fine-grained
  PATs do not work — see the warning at the top of [BOT_SETUP.md → Step 3](BOT_SETUP.md).
  Replace with a classic PAT generated from `donpetry-bot`'s account.
- The PAT was generated from the wrong account — `gh auth status` in the
  workflow log will show the actual login. Regenerate from `donpetry-bot`.
- The PAT is missing required scopes. Edit the token and ensure `repo`,
  `workflow`, and `read:org` are checked. Note: `read:org` is required not
  just for CODEOWNERS escalation but also to read team-based review requests —
  omitting it causes a hard prefetch failure on any PR with a team reviewer.
- The bot account doesn't have **Write** collaborator role on the target repo
  (Read or Triage isn't sufficient for review approvals).

### `gh pr view failed during metadata prefetch` / `Resource not accessible by personal access token (repository.pullRequest.reviewRequests.nodes.0.requestedReviewer)`
- The classic PAT is missing the `read:org` scope. This error occurs on any PR
  that has a **team** (not just a user) as a requested reviewer — the
  `reviewRequests.requestedReviewer` GraphQL field requires org-level member
  read access and is hard-blocked without it.
- Edit the token at **Settings → Developer settings → Tokens (classic) → Edit**
  and check `read:org`. No regeneration needed — the scope update takes effect
  immediately. See [BOT_SETUP.md → Step 3](bot-setup.md) and
  [MACHINE_USER_SETUP.md → Troubleshooting](machine-user-setup.md).

### Reviews not posting
- Run a dry-run to verify agent decision
- Check `scripts/review-one-pr.sh` and `scripts/post-pr-review.sh` for errors
- Verify branch protection rules allow the machine user as a reviewer

### PRs not auto-merging despite approval
- Check branch protection rules require approval (they do)
- Verify auto-merge is enabled in GitHub organization settings
- Confirm no other branch protection rules are blocking merge (e.g., required status checks)

## Machine User Details

The bot (`donpetry-bot`) authenticates as a machine user account with a classic PAT stored as the `DON_PETRY_BOT_GH_PAT` secret. The machine user is added to an org team listed in CODEOWNERS, so its approvals satisfy code owner review requirements.

For full setup instructions, see [MACHINE_USER_SETUP.md](MACHINE_USER_SETUP.md).

## Architecture

```
.github/workflows/
├── pr-review.yml                  # Hourly cascade
├── daily-pr-review-health.yml     # Daily health-check issue
├── repair-pr-approvals.yml        # One-off cleanup for legacy stuck PRs
├── claude.yml                     # @claude mention handler
└── dependabot-automerge.yml       # Dependabot PR auto-merge

scripts/
├── list-prs.sh                    # Enumerate candidate PRs (excludes BOT_USER's own)
├── review-batch.sh                # Per-PR loop wrapper used by pr-review.yml
├── review-one-pr.sh               # Cascade orchestration for one PR
├── post-pr-review.sh              # Post approval, rebase, auto-merge, escalate
├── request-codeowners-review.sh   # CODEOWNERS-based escalation helper
├── repair-pr-approvals.sh         # Backfill missing approvals (legacy cleanup)
├── pr_review_health.sh            # Health-check issue body generator
└── engine.sh                      # Engine abstraction (claude vs copilot)

prompts/
├── triage.md                      # Tier 1: scope assessment
├── single-review.md               # Tier 1 confirmation when triage is clean
├── deep-review.md                 # Tier 2: deep code review
├── rubber-duck.md                 # Tier 2: cross-engine adversarial review
├── synthesize.md                  # Tier 2: combine deep + rubber-duck verdicts
├── synthesize-duck.md             # Tier 2: same, when only duck flagged HIGH
├── security-audit.md              # Tier 3: security pass for HIGH-risk PRs
├── cascade-action.md              # Final action selection (approve/escalate)
└── shared.md                      # Shared context for all prompts
```

## Security Considerations

- **Classic PAT** with minimum required scopes: `repo`, `workflow`, `read:org`
- **1-year expiry** on PAT — set a calendar reminder to rotate
- **PAT** stored only in GitHub Secrets, never logged or committed
- **Rotation** — generate a new classic PAT from `donpetry-bot`, update `DON_PETRY_BOT_GH_PAT` secret, revoke old token

## Related Documentation

- [AGENT.md](AGENT.md) — Full agent capabilities and design
- [MACHINE_USER_SETUP.md](MACHINE_USER_SETUP.md) — Machine user creation, PAT setup, and rotation
