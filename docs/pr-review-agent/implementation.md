# Implementation Details

This document describes the current implementation of the PR Review Agent and key architectural decisions.

## Authentication

### Current Approach: Machine User with PAT

**Why Machine User?**
- ✅ Can be listed in CODEOWNERS via org team membership
- ✅ Approvals satisfy `require_code_owner_review` branch protection
- ✅ Simple PAT-based auth — no JWT generation step needed
- ✅ Works identically to a human reviewer from GitHub's perspective

**Previous Approach (Deprecated):**
- GitHub App (`petry-projects-pr-review-agent[bot]`) with auto-expiring JWT tokens
- Could not be listed in CODEOWNERS (GitHub platform limitation)
- Repos with `require_code_owner_review: true` were permanently blocked
- See [issue #27](https://github.com/don-petry/pr-review-agent/issues/27) for details

### Token Usage

All workflows use the `DON_PETRY_BOT_GH_PAT` org secret directly:
```yaml
env:
  GH_TOKEN: ${{ secrets.DON_PETRY_BOT_GH_PAT }}
```

The PAT is a fine-grained token scoped to the `petry-projects` organization with 90-day expiry. See [MACHINE_USER_SETUP.md](machine-user-setup.md) for rotation instructions.

## PR Enumeration

### Finding Candidate PRs

`scripts/list-prs.sh` finds open PRs authored by the authenticated user using:

```bash
gh search prs \
  --state open \
  --author "@me" \
  --draft=false \
  --json url,number,repository
```

**Important:** The authored PR search does NOT filter on `--checks`, allowing review of PRs that haven't passed CI yet (e.g., compliance-related PRs).

External reviews are filtered by `--checks success` to ensure the agent doesn't approve PRs with failing CI.

### No-op Detection

A PR is skipped (no-op) if the agent has already posted an approval review to it. This prevents duplicate reviews and respects the "already reviewed" state.

## Review Pipeline

The agent evaluates PRs through four sequential phases:

1. **Triage** (`prompts/triage.md`)
   - Quick scope assessment
   - Decides: proceed to deep review, security audit, or immediate rejection
   - Output: `{decision, reason, proceed_with}`

2. **Deep Review** (`prompts/deep-review.md`)
   - Code quality analysis
   - Correctness, style, test coverage
   - Output: `{issues, severity, recommendation}`

3. **Security Audit** (`prompts/security-audit.md`)
   - Vulnerability scanning
   - Permission model, dependencies, secrets
   - Output: `{vulnerabilities, risk_level, recommendation}`

4. **Synthesis** (`prompts/synthesize.md`)
   - Combines triage, deep review, and security findings
   - Makes approval/rejection decision
   - Generates review body with actionable feedback

### Verdict JSON

Instead of the agent directly posting reviews, the agent outputs JSON:

```json
{
  "verdict": "approved",
  "review_body": "Reviewed PR...\n\n✓ Code quality looks good...",
  "should_rebase": false,
  "labels_to_remove": ["needs-human-review"]
}
```

This JSON is captured by `scripts/review-one-pr.sh` and passed to `scripts/post-pr-review.sh` for execution.

## Approval gates

Before pr-review posts its approval, `scripts/review-one-pr.sh` runs a series of
deterministic gates that can defer or fail the review. Two are signal-incorporation
gates that withhold approval until an external finding is accounted for:

- **Advisory-bot gate** (`scripts/lib/advisory-review-gate.sh`, #457/#458) — waits
  for advisory review bots (Gemini, Copilot, SonarCloud, Codex) to submit before
  approving.
- **Maintainer issue-comment gate** (`scripts/lib/maintainer-comment-gate.sh`,
  #1290/#1813/#1918) — withholds approval while any PR *issue comment*
  (`gh pr comment` / the main comment box, which creates no review thread) lacks a
  **verified disposition**. The old push-timestamp model (a push postdating the
  comment cleared it) was retired in #1813 because GitHub now returns the head push
  timestamp as `null`; "addressed" now means the comment was minimized with
  classifier `RESOLVED`. Every issue comment — human *and* bot — must carry one,
  except for a narrow exemption set (ADR-0012, #2209): our own automation-marked
  comments and the auto-rebase conflict sentinel, an owner/member/collaborator's
  exact review request (`@<bot user> please review`), a comment they mark
  `<!-- maintainer:not-a-finding -->`, and clean informational status comments
  from registered reviewer bots (e.g. SonarCloud's "Quality Gate passed", #1918). It **fails closed**. See
  [maintainer-comment-gate.md](maintainer-comment-gate.md) for why a review thread
  blocks merge but a plain PR comment previously did not, and how the block clears.

## Approval and Auto-Merge

### Why Not Agent-Driven Posting?

Earlier versions attempted to have the agent execute bash commands:
```bash
gh pr review "$PR_URL" --approve --body "$BODY"
gh pr merge "$PR_URL" --auto --squash
```

This approach failed because:
- Agents are unreliable at executing bash from high-level prompts
- Token management is complex within agent context
- Error handling is difficult to reason about

### Current Approach: Deterministic Scripts

`scripts/post-pr-review.sh` is a pure bash script handling all GitHub operations:

```bash
#!/usr/bin/env bash
gh pr review "$PR_URL" --approve --body "$(cat "$BODY_FILE")" || true
gh api -X PUT "repos/$OWNER_REPO/pulls/$PR_NUM/update-branch"
gh pr merge "$PR_URL" --auto --squash
gh pr edit "$PR_URL" --remove-label needs-human-review
```

Benefits:
- ✅ Deterministic — no AI decision-making on edge cases
- ✅ Testable — can be run standalone
- ✅ Observable — direct access to gh CLI output and errors
- ✅ Recoverable — can be re-run if it fails

### Separation of Concerns

- **Agent responsibility:** Analyze code and output decision as JSON
- **Infrastructure responsibility:** Execute GitHub operations reliably

This separation makes the system more robust and easier to debug.

## Stuck PR Cleanup

### The Problem

An earlier bug caused the agent to post comments with `decision=approved` instead of actual approval reviews. This meant:
- PRs had agent approval markers
- But no actual GitHub approval review
- So auto-merge didn't trigger

### The Solution

`scripts/fix-stuck-prs.sh` identifies and fixes these PRs:

```bash
# Find PRs with marker comments
MARKER_COUNT=$(gh pr view "$url" --json comments \
  --jq '[.comments[] | select(.body | contains("pr-review-agent v1"))] | length')

# Check if approval review exists
APPROVAL_COUNT=$(gh pr view "$url" --json reviews \
  --jq '[.reviews[] | select(.state == "APPROVED")] | length')

# If marker but no approval, post review
if [ "$MARKER_COUNT" -gt 0 ] && [ "$APPROVAL_COUNT" -eq 0 ]; then
  gh pr review "$url" --approve
  gh pr merge "$url" --auto --squash
fi
```

This script runs with machine user PAT credentials that can approve PRs across the organization.

## Rate Limiting and Fallback

The `scripts/review-batch.sh` script includes fallback logic:

```bash
# Fallback chain: claude -> gemini -> copilot
if [ "$rc" -eq 2 ] && [ "${REVIEW_ENGINE:-claude}" = "claude" ]; then
  export REVIEW_ENGINE=gemini
  # ... retry this PR with gemini ...
fi

if [ "$rc" -eq 2 ] && [ "${REVIEW_ENGINE}" = "gemini" ]; then
  export REVIEW_ENGINE=copilot
  # ... retry this PR with copilot ...
fi
```

If Claude hits rate limits, the batch switches to Gemini, and then to GitHub Copilot if needed. This ensures reviews continue even under high load.

## Metrics and Monitoring

Key metrics tracked in workflow logs:
- **Reviews posted:** Number of PRs actually approved
- **No-ops skipped:** PRs already reviewed, not re-reviewed
- **Failures:** PRs that had errors during review
- **Engine fallbacks**: Cumulative count and specific engines used (e.g., "gemini, copilot")

View recent runs:
```bash
gh run list --repo don-petry/pr-review-agent -w pr-review.yml -L 5
```

Check specific run output:
```bash
gh run view <run-id> --repo don-petry/pr-review-agent --log
```

## Configuration

### Environment Variables (in workflows)

| Variable | Default | Purpose |
|----------|---------|---------|
| `REVIEW_ENGINE` | `claude` | Primary review engine: `claude`, `gemini`, or `copilot` |
| `DRY_RUN` | `true` | If true, don't post reviews |
| `MAX_PRS` | `10` | Max reviews per run |
| `CANDIDATE_LIMIT` | `100` | Max candidates scanned |
| `MAX_REVIEW_CYCLES` | `3` | Max review iterations before human escalation |
| `DELEGATION_ORGS` | Empty | Orgs where AI can auto-fix findings |

### Secrets

| Secret | Purpose |
|--------|---------|
| `DON_PETRY_BOT_GH_PAT` | Machine user PAT for GitHub API access (BOT_USER) |
| `GH_PAT` | User PAT with Copilot subscription (fallback source) |
| `CLAUDE_CODE_OAUTH_TOKEN` | Claude Code authentication |
| `GOOGLE_API_KEY` | Gemini API authentication |

## File Structure

```
├── .github/workflows/
│   ├── pr-review.yml              # Main hourly review workflow
│   └── fix-stuck-prs.yml          # Cleanup workflow
│
├── scripts/
│   ├── list-prs.sh                # Enumerate candidate PRs
│   ├── review-one-pr.sh           # Orchestrate single PR review
│   ├── post-pr-review.sh          # Post approval and auto-merge
│   └── fix-stuck-prs.sh           # Fix PRs with comments but no reviews
│
├── prompts/
│   ├── shared.md                  # Shared context for all reviews
│   ├── triage.md                  # Quick scope assessment
│   ├── deep-review.md             # Code quality analysis
│   ├── security-audit.md          # Vulnerability scanning
│   ├── synthesize.md              # Combine findings, make decision
│   └── cascade-action.md          # Review coordination (legacy)
│
├── setup.md                       # Quick start guide
├── machine-user-setup.md          # Machine user and PAT setup
├── implementation.md              # This file
└── README.md                       # Overview
```

## Future Improvements

- [ ] Webhook-based triggering instead of hourly cron (faster feedback)
- [ ] Per-repo configuration for review strictness
- [ ] Machine learning to learn from human review feedback
- [ ] Integration with issue tracking systems (Linear, Jira)
- [ ] Custom review templates per organization
- [ ] Review history and analytics dashboard
