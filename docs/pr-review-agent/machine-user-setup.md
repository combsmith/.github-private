# Machine User Setup for PR Review Agent

The agent authenticates via a **machine user** GitHub account whose classic
PAT is stored in the workflow secret `DON_PETRY_BOT_GH_PAT`. The bot posts
approvals using this token; its review counts as a CODEOWNERS approval when
the bot is in the team listed in `CODEOWNERS`.

> [!IMPORTANT]
> **Use a classic PAT. Fine-grained PATs do not work for this workflow.**
>
> After the migration to `petry-projects/.github-private`, fine-grained PATs
> fail the GraphQL `addPullRequestReview` mutation with:
>
> ```
> failed to create review: GraphQL: Resource not accessible by personal access token (addPullRequestReview)
> ```
>
> The failure persists even when every obvious gate is satisfied: the org owner
> has approved the token request, fine-grained PATs are allowed for
> `petry-projects`, the bot has Write collaborator access on the target repo,
> and the PAT lists the right repository / permissions. Classic PATs with
> `repo` scope work; fine-grained ones do not. If you ever see the error above
> in a workflow log, the secret is holding a fine-grained token — generate a
> classic one and replace it.
>
> **Dual-secret setup (current):** the approval-path workflows read
> `${{ secrets.DON_PETRY_BOT_GH_PAT_CLASSIC || secrets.DON_PETRY_BOT_GH_PAT }}` —
> i.e. they **prefer the classic PAT** in `DON_PETRY_BOT_GH_PAT_CLASSIC` (scopes
> `repo`, `workflow`, `read:org`) and fall back to the fine-grained
> `DON_PETRY_BOT_GH_PAT` only if it is unset. This lets the bot keep a
> least-privilege fine-grained token for read/scan workflows while using the
> classic token solely where `addPullRequestReview` requires it. To enable
> approvals, set `DON_PETRY_BOT_GH_PAT_CLASSIC`.

## Why a machine user

- It can be added to an org team referenced in `CODEOWNERS`, so its approvals
  satisfy code-owner review requirements.
- It works identically to a human reviewer from GitHub's perspective —
  no JWT exchange, no app installation flow, no opaque integration ID.
- A simple PAT-based auth keeps the workflow short.

(GitHub Apps were tried and abandoned: app accounts cannot be in `CODEOWNERS`,
so app-account approvals don't satisfy code-owner requirements. See the
"Trade-offs" table at the bottom for the full comparison.)

## Step 1: Create the machine user account

1. Sign out of your primary account (or use a private window).
2. Create a new GitHub account, e.g. `donpetry-bot`. Use a dedicated email
   alias you can route to your inbox (e.g. `you+donpetry-bot@gmail.com`).
3. Verify the email, complete account setup, and turn on 2FA.

## Step 2: Add the bot to the org and the CODEOWNERS team

1. Sign in as your primary account (org owner).
2. **github.com/organizations/petry-projects/settings/members** →
   **Invite member** → enter `donpetry-bot` → role: **Member**.
3. Accept the invite from the bot account.
4. Create or open the org team that's referenced in `CODEOWNERS`
   (e.g. `petry-projects/pr-reviewers`).
5. Add `donpetry-bot` to that team.
6. On every target repo, ensure the bot is a **Write** collaborator
   (org-level team membership grants the role; verify on
   `github.com/<org>/<repo>/settings/access`).

In each repo whose PRs the agent reviews, the `CODEOWNERS` file should
reference the team:

```
# .github/CODEOWNERS
* @petry-projects/pr-reviewers
```

Or path-specific rules as needed.

## Step 3: Generate a classic PAT for the bot

1. Sign in **as the bot** (`donpetry-bot`). The PAT must be created from the
   bot's account, not yours — sign out of your primary account first.
2. **Settings → Developer settings → Personal access tokens → Tokens (classic)**
   → **Generate new token (classic)**.
3. Settings:
   - **Note:** `pr-review-agent`
   - **Expiration:** 1 year (set a calendar reminder to rotate)
   - **Scopes:**
     - ✅ `repo` (full control of private repos) — required for the
       `addPullRequestReview` mutation
     - ✅ `workflow` — required when AI delegation pushes workflow-file changes
     - ✅ `read:org` — **required** to read team-based review requests; the
       `reviewRequests.requestedReviewer` GraphQL field returns
       `Resource not accessible by personal access token` for any PR with
       a team reviewer when this scope is absent. Also enables `@org/team`
       resolution in CODEOWNERS escalations.
4. **Generate token** and copy it immediately (you won't see it again).

## Step 4: Store the PAT in `petry-projects/.github-private`

Sign back in as your primary account, then either via the UI:

**github.com/petry-projects/.github-private/settings/secrets/actions**
→ **New repository secret** (or **Update**) → name `DON_PETRY_BOT_GH_PAT`,
value = the token from Step 3.

Or via `gh`:

```bash
gh secret set DON_PETRY_BOT_GH_PAT \
  --repo petry-projects/.github-private \
  --body "<paste-token>"
```

Verify:

```bash
gh secret list --repo petry-projects/.github-private | grep DON_PETRY_BOT_GH_PAT
```

### Secret naming reference

PAT secrets follow the schema **`GH_PAT_<ACCOUNT>[_<QUALIFIER>]`**, where `<ACCOUNT>`
is the GitHub login upper-snake-cased (`don-petry` → `GH_PAT_DON_PETRY`). This makes
the *owning account* obvious from the secret name, resolving the ambiguity that let dev-lead
regress to committing as the bot ([#1316](https://github.com/petry-projects/.github-private/issues/1316)).
Each persona declares which account/secret it acts as in `runtime.identity`
(`personas/<id>/persona.yml`); see `standards/persona-standards.md` §5.1.

| Secret | Account | Purpose |
|--------|---------|---------|
| `GH_PAT_DON_PETRY` | don-petry | Write/workflows PAT — the account dev-lead and the persona runner commit/push/comment as. Also exposed as `COPILOT_GITHUB_TOKEN` for the Copilot review engine: Copilot access is an **account-subscription entitlement** on don-petry, not a token scope, so this same PAT authenticates the engine — no separate secret. **Canonical name** for the PAT formerly stored as `GH_PAT_WORKFLOWS`. |
| `DON_PETRY_BOT_GH_PAT` | donpetry-bot | Machine user / bot reviewer PAT. Used by `pr-review.yml`, `repair-pr-approvals.yml`, `daily-pr-review-health.yml` for GitHub API auth as the bot. Grandfathered name (pre-dates the schema). |
| `DON_PETRY_BOT_GH_PAT_CLASSIC` | donpetry-bot | Classic PAT for the bot; required for `gh pr review --approve`. Preferred over the fine-grained secret when set. Grandfathered. |
| `GOOGLE_API_KEY` | — | API key for Google AI (Gemini). Used by the `gemini` engine for triage, deep review, and audit tiers. |

> **Migration:** `GH_PAT_WORKFLOWS` → `GH_PAT_DON_PETRY`. Workflows read
> `${{ secrets.GH_PAT_DON_PETRY || secrets.GH_PAT_WORKFLOWS }}` during the transition, so
> **create the new secret as a copy of the old one**; once confirmed present, a follow-up
> drops the `|| secrets.GH_PAT_WORKFLOWS` fallbacks and deletes the old secret.
>
> The Copilot engine now authenticates with the single `GH_PAT_DON_PETRY` classic PAT
> (#1327); the only requirement is a **Copilot subscription on the don-petry account** — no
> separate Copilot secret is needed. The former `GH_PAT` / `GH_PAT_DON_PETRY_COPILOT` names
> are kept only as a transitional by-name fallback in `pr-review.yml` for callers not yet on
> `secrets: inherit` (currently `TalkTerm`); once those migrate, a follow-up drops the
> fallback and deletes `GH_PAT`.

## Step 5: Verify the setup

Trigger a one-shot dry-run of the PR review workflow:

```bash
gh workflow run pr-review.yml \
  --repo petry-projects/.github-private \
  -f dry_run=true
```

Then read the run's `Install review engine CLIs` step. The first command is
`gh auth status`, which should report the bot's login (not yours) and the
three scopes from Step 3:

```
Logged in to github.com account donpetry-bot
- Token scopes: 'read:org', 'repo', 'workflow'
```

If the login is your primary account, the secret is holding the wrong PAT —
recreate it from the bot's account (Step 3) and update the secret (Step 4).

If the run reaches the `[approve] Posting APPROVED review...` line and
returns the `Resource not accessible by personal access token` error, the
secret is holding a fine-grained PAT (see the warning at the top).

## PAT rotation

Classic PATs expire on the date set when generated (1 year recommended).

1. Sign in as the bot.
2. Generate a new classic PAT with the same scopes.
3. Update the secret:
   ```bash
   gh secret set DON_PETRY_BOT_GH_PAT \
     --repo petry-projects/.github-private \
     --body "<new-token>"
   ```
4. Revoke the old token from the bot's
   **Settings → Developer settings → Tokens (classic)** page.

## Trade-offs vs GitHub App

| Aspect              | Machine User (classic PAT)                | GitHub App                       |
|---------------------|-------------------------------------------|----------------------------------|
| CODEOWNERS support  | Yes (team membership grants approval)     | No (apps can't be in CODEOWNERS) |
| Token lifetime      | Manual (1 year recommended)               | Automatic (1-hour JWT)           |
| Permission model    | PAT scopes (org/repo coarse)              | Fine-grained app manifest        |
| Account overhead    | Requires a free GitHub account + 2FA      | No human account                 |
| Branch-protection / rulesets bypass | Honored when bot is on the bypass list | Sometimes blocked                |
| Setup complexity    | Low                                       | Medium                           |

## Troubleshooting

### `Resource not accessible by personal access token (addPullRequestReview)`

The PAT in `DON_PETRY_BOT_GH_PAT` is fine-grained, not classic. Generate a
classic PAT (Step 3) and update the secret (Step 4). The fine-grained version
is blocked by an org-policy gate that has no UI surface — there's no
configuration that makes it work.

### `Missing required token scopes: 'read:org'` or `gh pr view failed during metadata prefetch`

The classic PAT was generated without `read:org`. This scope is required for two reasons:

1. **Team-based review requests** — the `reviewRequests.requestedReviewer` GraphQL field
   returns `Resource not accessible by personal access token` for any PR that has a team
   (not just a user) as a requested reviewer. This causes a hard prefetch failure and the
   PR is skipped entirely.
2. **CODEOWNERS escalation** — `@org/team` mentions cannot be resolved without org read access.

Edit the token at **Settings → Developer settings → Tokens (classic) → Edit** and check
the `read:org` box. (No need to regenerate — editing scopes takes effect immediately.)

### `gh auth status` reports the wrong account

The PAT was created from your primary account by mistake, not the bot.
Sign out of your primary account, sign in as the bot, regenerate the token
(Step 3), and update the secret (Step 4).

### Approval doesn't satisfy code-owner requirement

- Confirm the bot is on the team listed in the repo's `CODEOWNERS`
  (org admin → team → Members).
- Validate `CODEOWNERS` syntax:
  `gh api repos/<owner>/<repo>/codeowners/errors`
- Confirm the repo's branch protection / ruleset has
  `Require review from Code Owners` enabled.

### Token expired

Sign in as the bot, regenerate the classic PAT (Step 3), and update the
secret (Step 4).

## References

- [GitHub: Managing CODEOWNERS](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/about-code-owners)
- [GitHub: Classic PATs](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens#personal-access-tokens-classic)
- [`AGENT.md`](AGENT.md) — full agent design and runtime behavior
- [`BOT_SETUP.md`](BOT_SETUP.md) — abbreviated setup checklist
