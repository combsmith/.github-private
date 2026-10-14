# donpetry-bot Setup Instructions

This guide sets up the bot account that posts PR approvals on behalf of the PR Review Agent.

**Why a separate bot account?** GitHub blocks self-approvals — a user cannot approve their own PR. The bot account acts as a reviewer, allowing don-petry's PRs to be auto-approved and auto-merged.

## Step 1: Create the Bot Account

1. Sign out of GitHub (use private browser window or different browser)
2. Go to https://github.com/signup
3. Create account with:
   - **Username:** `donpetry-bot`
   - **Email:** Use a dedicated alias (e.g., `you+donpetry-bot@gmail.com`)
4. Verify the email address
5. Sign back in as **don-petry**

## Step 2: Add Bot to Organization

1. Go to https://github.com/organizations/petry-projects/settings/members
2. Click **Invite member**
3. Enter `donpetry-bot`
4. Select Role: **Member**
5. Send invitation
6. Sign in as **donpetry-bot** and accept the invitation
7. Sign back in as **don-petry**

## Step 3: Create **Classic** PAT for Bot Account

> [!IMPORTANT]
> **Use a classic PAT. Fine-grained PATs do not work.**
>
> The agent posts approvals via the GraphQL `addPullRequestReview` mutation.
> Fine-grained tokens get blocked at the org policy layer even after every
> obvious requirement is met (org token approval granted, fine-grained PATs
> allowed for the org, repo access granted, Write collaborator role assigned).
> The failure is silent until the workflow runs and reports:
>
> ```
> failed to create review: GraphQL: Resource not accessible by personal access token (addPullRequestReview)
> ```
>
> If you see that error after a known-good PAT setup, the secret holds a
> fine-grained token. Replace it with a classic PAT generated below.

1. Sign in as **the bot account** (e.g. `donpetry-bot`) — sign out of don-petry
   first, or use a private window. The PAT must be generated **from the bot's
   account**, not yours.
2. Go to **Settings → Developer settings → Personal access tokens → Tokens (classic)**
3. Click **Generate new token (classic)**
4. Fill in:
   - **Note:** `pr-review-agent`
   - **Expiration:** 1 year (set calendar reminder to rotate)
   - **Scopes:**
     - ✅ `repo` (full control of repositories) — required for `addPullRequestReview`
     - ✅ `workflow` — required when AI delegation pushes workflow-file changes
     - ✅ `read:org` — **required** to read team-based review requests (`reviewRequests.requestedReviewer`
       fails with a GraphQL permission error for any PR that has a team reviewer when this scope is absent);
       also enables team-based CODEOWNERS escalation
5. Click **Generate token**
6. **Copy the token immediately** (you won't see it again)
7. Store it temporarily (we'll add to repo secret next)

## Step 4: Add DON_PETRY_BOT_GH_PAT Secret to Repo

1. Sign back in as **don-petry**
2. Go to https://github.com/petry-projects/.github-private/settings/secrets/actions
3. Click **New repository secret**
4. Fill in:
   - **Name:** `DON_PETRY_BOT_GH_PAT`
   - **Value:** Paste the bot token from Step 3
5. Click **Add secret**

**Verify:** The secret should now appear in the list as `DON_PETRY_BOT_GH_PAT`

## Step 5: Add Bot to Branch Protection Rules

The bot needs to be allowed as an approver in branch protection settings.

1. Go to https://github.com/petry-projects/.github-private/settings/branches
2. Click on the `main` branch protection rule (or create one)
3. In "Require pull request reviews before merging":
   - Make sure the bot is **NOT** in the "Dismiss stale pull request approvals" dismissal restrictions
   - Add `donpetry-bot` to the list of **allowed approvers** if that field exists
4. Save

**Alternative:** If using GitHub Rulesets instead of branch protection:
1. Go to https://github.com/petry-projects/.github-private/rules
2. Edit the main branch ruleset
3. Under "Require reviews," ensure `donpetry-bot` can post approvals
4. Save

## Step 6: Configure Across Multiple Repos

Repeat **Step 5** for any other repos where the bot should approve PRs:
- `petry-projects/ContentTwin`
- `petry-projects/TalkTerm`
- `petry-projects/markets`
- Any other repos in the `petry-projects` org

## Step 7: Test the Setup

1. Trigger a dry-run of the PR-review workflow to verify authentication:
   ```bash
   gh workflow run pr-review.yml --repo petry-projects/.github-private -f dry_run=true
   ```

2. Check the workflow logs (substitute the run number from the previous
   command's output, or list runs with `gh run list --repo petry-projects/.github-private -w pr-review.yml -L 1`):
   ```bash
   gh run view <run-number> --repo petry-projects/.github-private --log
   ```

3. The `Install review engine CLIs` step calls `gh auth status` first; it
   should show:
   ```
   Logged in to github.com account donpetry-bot
   - Token scopes: 'read:org', 'repo', 'workflow'
   ```

4. Once authentication looks correct, flip the org variable to live mode:
   ```bash
   gh variable set LIVE_MODE --body true --repo petry-projects/.github-private
   ```
   The next scheduled `:07` cron tick (or a fresh `workflow_dispatch` with
   `dry_run=false`) will post real approvals.

## Troubleshooting

### Issue: Still authenticating as `don-petry`
- Verify `DON_PETRY_BOT_GH_PAT` secret contains the **bot account's** PAT, not don-petry's token
- Check the PAT was generated from donpetry-bot's account, not don-petry's

### Issue: "Review Can not approve your own pull request"
- The PAT is don-petry's token (causes self-approval attempts)
- Generate a fresh PAT from donpetry-bot's account

### Issue: Bot can't approve PRs in certain repos
- Verify bot is a member of the organization
- Check branch protection rules aren't blocking the bot
- Verify bot has `repo` scope in its PAT

### Issue: `gh pr view failed during metadata prefetch` / `Resource not accessible by personal access token (repository.pullRequest.reviewRequests.nodes.0.requestedReviewer)`
- The classic PAT is missing `read:org`. This error surfaces the first time a PR
  with a **team** requested reviewer is encountered — the `reviewRequests.requestedReviewer`
  GraphQL field requires org-level member read access.
- Edit the token at **Settings → Developer settings → Tokens (classic) → Edit** and
  check the `read:org` box. No need to regenerate — editing scopes takes effect immediately.
- Verify by re-running: `gh workflow run pr-review.yml --repo petry-projects/.github-private -f pr_url=<pr-url> -f force_review=true`

## Rotating the Token (Annually)

1. Sign in as **donpetry-bot**
2. Go to **Settings → Developer settings → Tokens (classic)**
3. Generate a new token with same settings
4. Update the `DON_PETRY_BOT_GH_PAT` secret in the repo with the new token
5. Delete the old token
6. Set a new calendar reminder for next year

## Security Notes

- The `DON_PETRY_BOT_GH_PAT` is a secret and should never be logged or committed
- The bot account should only be used for automated reviews, not manual work
- Rotate the token annually
- If the token is compromised, delete it immediately and generate a new one
