# PR Review Agent - Status Report

**Date:** April 26, 2026  
**Status:** ✅ **OPERATIONAL**

## What Was Done

### 1. Machine User Authentication ✅
- Machine user account with fine-grained PAT stored as `DON_PETRY_BOT_GH_PAT` org secret
- Added to org team listed in CODEOWNERS — approvals satisfy code owner review requirements
- Configured permissions: Contents (read), Pull requests (read/write), Checks (read)
- All workflows use `${{ secrets.DON_PETRY_BOT_GH_PAT }}` directly (no token generation step needed)

**Why Machine User?** (migrated from GitHub App — see [issue #27](https://github.com/petry-projects/.github-private/issues/27))
- GitHub Apps cannot be listed in CODEOWNERS (platform limitation)
- Machine user approvals satisfy `require_code_owner_review` branch protection
- Simpler auth: direct PAT, no JWT generation step

### 2. Comprehensive Documentation ✅
Created in repository:
- **setup.md** — Quick reference guide with configuration, secrets, commands, troubleshooting
- **implementation.md** — Technical deep dive: architecture, design decisions, stuck PR cleanup
- **documentation-index.md** — Index linking all documentation
- **Updated README.md** — Status badge and quick links
- **machine-user-setup.md** — Machine user account and PAT setup instructions

### 3. Stuck PR Cleanup ✅ (Approvals Posted)
Fixed 24 stuck PRs across three repositories:
- **ContentTwin:** PRs #97-109 (13 PRs)
- **TalkTerm:** PRs #112, #121 (2 PRs)
- **Markets:** PRs #126, #128-130, #133+ (9+ PRs)

**What was the problem?**
Agent was posting comments with `decision=approved` instead of actual GitHub approval reviews. Approval reviews are required for branch protection, comments don't satisfy the requirement.

**How it was fixed:**
`scripts/fix-stuck-prs.sh` identifies PRs with marker comments but no approval reviews, then posts actual approval reviews using the machine user PAT.

**Current Status:**
- ✅ Approval reviews posted to all 24 stuck PRs
- ⚠️ Auto-merge may require additional repo settings
- ❌ PRs still OPEN (approvals in place, but manual merge or permission expansion needed)

**Verification:**
```
ContentTwin #109: 1 approval review(s) ✓ (status: OPEN)
ContentTwin #108: 1 approval review(s) ✓ (status: OPEN)
ContentTwin #107: 1 approval review(s) ✓ (status: OPEN)
ContentTwin #100: 2 approval review(s) ✓ (status: OPEN)
```

**Next Step:** Either:
1. Manually merge the PRs (they now have approvals)
2. Enable auto-merge in repo settings (if not already enabled)

## How the System Works

### Hourly Review Cycle
1. Enumerate open PRs authored by don-petry
2. For each PR: triage → deep review → security audit → synthesis
3. Post approval review if PR passes all checks
4. Enable auto-merge (squash strategy)
5. Update labels if needed

### Workflow Files
- `.github/workflows/pr-review.yml` — Main hourly review (runs at :07 every hour)
- `.github/workflows/fix-stuck-prs.yml` — Manual cleanup workflow for stuck PRs

### Scripts
- `scripts/list-prs.sh` — Enumerate candidate PRs
- `scripts/review-one-pr.sh` — Orchestrate review for single PR
- `scripts/post-pr-review.sh` — Post approval and enable auto-merge
- `scripts/fix-stuck-prs.sh` — Fix PRs with comments but no approvals

## Architectural Decisions

### Agent vs Infrastructure Separation
- **Agent:** Analyzes code, outputs verdict JSON
- **Infrastructure:** Executes GitHub operations (posting, rebasing, auto-merge)

This separation makes the system more robust and easier to debug. Agent decisions are content-focused; infrastructure execution is deterministic.

### Machine User over GitHub App
Previously used: GitHub App (`petry-projects-pr-review-agent[bot]`) with auto-expiring JWT tokens.

**Why we switched:** GitHub Apps cannot be listed in CODEOWNERS files, so repos with `require_code_owner_review: true` were permanently blocked. Machine user accounts can be added to org teams listed in CODEOWNERS, resolving this limitation. See [issue #27](https://github.com/petry-projects/.github-private/issues/27).

## Configuration

### Required Secrets
```bash
gh secret set DON_PETRY_BOT_GH_PAT --repo petry-projects/.github-private --body "<machine-user-pat>"
gh secret set CLAUDE_CODE_OAUTH_TOKEN --repo petry-projects/.github-private
```

### Optional Variables
```bash
# Engine: claude (default) or copilot
gh variable set REVIEW_ENGINE --repo petry-projects/.github-private --body "claude"

# Live mode: true to post reviews, false for dry-run
gh variable set LIVE_MODE --repo petry-projects/.github-private --body "true"

# Max reviews per run
gh variable set MAX_PRS --repo petry-projects/.github-private --body "10"
```

## Usage

### Check Recent Reviews
```bash
gh run list --repo petry-projects/.github-private -w pr-review.yml -L 5
gh run view <run-id> --repo petry-projects/.github-private --log
```

### Trigger Manual Review
```bash
# Dry-run (no changes)
gh workflow run pr-review.yml --repo petry-projects/.github-private -f dry_run=true

# Review specific PR
gh workflow run pr-review.yml --repo petry-projects/.github-private \
  -f pr_url=https://github.com/petry-projects/ContentTwin/pull/123 \
  -f dry_run=false

# Fix stuck PRs
gh workflow run fix-stuck-prs.yml --repo petry-projects/.github-private -f dry_run=false
```

## Known Limitations

1. **Auto-merge requires repo settings**: Auto-merge must be enabled in each repo's settings for `gh pr merge --auto` to work.

2. **PAT rotation**: Machine user PATs expire (90-day recommended). Set a calendar reminder to rotate. See [machine-user-setup.md](machine-user-setup.md).

## Support & Troubleshooting

See **[setup.md](setup.md)** for:
- Permission errors and fixes
- Authentication issues
- Workflow failures
- Rate limiting and fallback engines

See **[implementation.md](implementation.md)** for:
- Architecture details
- Design rationale
- How each component works
- Future improvement ideas

## Next Steps (Optional)

- [ ] Expand review engine to handle more repo types
- [ ] Add webhook-based triggering for faster feedback
- [ ] Set up review analytics dashboard
- [ ] Integrate with project management systems (Linear, Jira)

---

**Created by:** Claude Code Agent  
**Repository:** petry-projects/.github-private  
**Organization:** petry-projects
