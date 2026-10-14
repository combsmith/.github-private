# Scenarios: standards-sync

## Overview

The `standards-sync` workflow runs on a monthly schedule (first Monday of each month)
and checks all org repos against the org standards defined in `AGENTS.md`, `CODEOWNERS`,
and required workflow files. For any repo that is out of sync, it opens a PR with the
required additions.

**Trigger:** `schedule` (monthly, first Monday at 09:00 UTC — `0 9 1-7 * 1`)
**Outputs:** PRs opened on out-of-sync repos

---

## Scenario 1: Repo missing AGENTS.md

**Given** a repo in the `petry-projects` org does not have an `AGENTS.md` file
**When** the monthly schedule fires
**Then**
- the workflow detects the missing file
- a PR is opened on that repo adding `AGENTS.md` with the org-standard content
- the PR title is `chore: add AGENTS.md (standards-sync)`
- the PR is labelled `standards-sync`

**Assertions:**
- A PR is opened on the out-of-sync repo
- The PR diff contains `AGENTS.md` as a new file
- No PR is opened if the repo already has `AGENTS.md`

---

## Scenario 2: Repo missing CODEOWNERS

**Given** a repo does not have `.github/CODEOWNERS`
**When** the monthly schedule fires
**Then**
- the workflow detects the missing file
- a PR is opened adding a default `CODEOWNERS` pointing at org-wide owners

**Assertions:**
- PR contains `.github/CODEOWNERS` as a new file
- File content matches the org-standard template

---

## Scenario 3: Repo already compliant

**Given** a repo has all required files: `AGENTS.md`, `.github/CODEOWNERS`
**When** the monthly schedule fires
**Then**
- no PR is opened for that repo
- the workflow logs a "compliant" notice for the repo

**Assertions:**
- No new PRs are created for compliant repos
- Workflow exits 0

---

## Scenario 4: PR already open for the repo

**Given** a standards-sync PR is already open for a repo (from a previous run)
**When** the monthly schedule fires again
**Then**
- the workflow detects the existing open PR
- no duplicate PR is opened
- the workflow logs "skipping — PR already open" for that repo

**Assertions:**
- No duplicate PR is created
- Idempotency: running twice produces the same state

---

## Scenario 5: Archived or private repo

**Given** a repo in the org is archived
**When** the monthly schedule fires
**Then**
- the workflow skips archived repos
- no PR is opened on an archived repo (GitHub API would reject it anyway)

**Assertions:**
- Archived repos are excluded from the sync list
- Script does not emit errors for archived repos

---

## Scenario 6: Cross-org compliance summary

**Given** the workflow has run across all repos
**When** the run completes
**Then**
- a summary issue is opened in `.github-private` listing compliance status
- the issue shows: total repos scanned, compliant count, PRs opened count, security settings applied count

**Assertions:**
- A summary issue is created in `petry-projects/.github-private`
- Issue body contains a compliance table or list
- Issue is labelled `standards-sync` and `automated-report`

---

## Scenario 7: Repo missing secret_scanning_ai_detection

**Given** a repo in the `petry-projects` org has `secret_scanning_ai_detection` set to `null` (not enabled)
**When** the monthly schedule fires
**Then**
- the workflow detects the missing security setting via the GitHub API
- it applies a PATCH to `repos/{repo}` enabling `secret_scanning_ai_detection`
- the setting change is reflected in the summary issue action column

**Assertions:**
- `settings_applied` counter increments for the affected repo
- Summary row for the repo notes the security setting was enabled
- No PR is opened (security settings are applied directly via API, not via PR)

---

## Scenario 8: Repo already has secret_scanning_ai_detection enabled

**Given** a repo already has `secret_scanning_ai_detection` set to `enabled`
**When** the monthly schedule fires
**Then**
- the workflow reads the current setting and skips the PATCH call
- no change is made to the repo

**Assertions:**
- `settings_applied` counter does NOT increment for this repo
- Script logs `[ok]` for the repo (not `[fix]`)
- Idempotency: running twice produces the same state

---

## Scenario 9: secret_scanning_ai_detection cannot be enabled (Advanced Security unavailable)

**Given** a repo does not have GitHub Advanced Security enabled
**When** the monthly schedule fires and the PATCH to enable `secret_scanning_ai_detection` fails
**Then**
- the workflow logs a warning for the repo
- no crash or exit-1 occurs (graceful degradation)
- the summary issue notes an error for the setting

**Assertions:**
- Script continues processing remaining repos after the failed PATCH
- Warning message includes the setting name and a note about Advanced Security
- `settings_applied` counter does NOT increment for the failed repo

---

## Scenario 10: All PP_REQUIRED_SA_SETTINGS are enforced by the sync

**Given** a repo is missing any of the settings in `PP_REQUIRED_SA_SETTINGS`:
  `secret_scanning`, `secret_scanning_push_protection`, `secret_scanning_ai_detection`,
  `secret_scanning_non_provider_patterns`, `dependabot_security_updates`
**When** the monthly schedule fires
**Then**
- the workflow detects each missing setting via `REQUIRED_SECURITY_SETTINGS` (derived from `PP_REQUIRED_SA_SETTINGS` in `scripts/lib/push-protection.sh`)
- each setting is patched individually so that a failure on one does not block the others
- the summary issue notes which settings were enabled and which errored

**Assertions:**
- All five settings in `PP_REQUIRED_SA_SETTINGS` appear in `REQUIRED_SECURITY_SETTINGS`
- Adding a new key to `PP_REQUIRED_SA_SETTINGS` in the lib automatically extends the sync

---

## Scenario 11: One required security setting unavailable, others still applied

**Given** a repo has `secret_scanning_ai_detection` unavailable (no Advanced Security licence)
  but the other four settings are patchable
**When** the monthly schedule fires
**Then**
- the PATCH for `secret_scanning_ai_detection` returns a 422 error
- the remaining four settings are still patched successfully in their own independent PATCH calls
- the summary issue row for the repo shows which settings were enabled and which errored

**Assertions:**
- `settings_applied` increments by 4 (the four that succeeded)
- The repo row in the summary notes `secret_scanning_ai_detection:error` alongside the four `:enabled` entries
- Script exits 0 for the run (individual setting failures are non-fatal)
