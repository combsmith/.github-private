# 0015. Repo-declared required checks merge into `code-quality`

## Status

accepted

## Context

The `code-quality` ruleset is the org's required-checks gate, codified in
`combsmith/.github` `standards/rulesets/code-quality.json`. The weekly
`apply-repo-settings` self-heal runs `apply-rulesets.sh`, which replaces the
live ruleset with that file in full. `check_legacy_rulesets()` in the compliance
audit reports any other ruleset on the default branch as an error, because only
`pr-quality` and `code-quality` are sanctioned.

That left a repo no durable, compliant way to require a check of its own:

- A context added by hand to `code-quality` disappears every Monday.
- A separate ruleset survives, but is reported as a `legacy-ruleset-*` error
  each week.
- Classic branch protection can't pin a check to an app (`integration_id`), and
  it adds a third mechanism for protecting branches.

Organization-level rulesets would solve this but aren't available for these OSS
repos. The first real case was `empower-personal-dashboard` making `mutation (all)`
a required check (combsmith/.github#1410). It had to use a separate
`mutation-testing` ruleset, which the audit flags.

The audit's own content check already treats required checks as a minimum
(subset semantics), and the standard says repo-specific additional checks are
allowed. The applier and the legacy-ruleset audit didn't follow that rule.

## Decision

We will let each repo declare extra required checks in its own
`.github/required-checks.json`, and merge them into `code-quality`:

- **Format:** `{"version": 1, "required_status_checks": [{"context": ..., "integration_id": ...}]}`.
  `integration_id` is mandatory, so every declared check stays pinned to the app
  that must report it.
- **Allowlist, not union:** `apply-rulesets.sh` adds exactly the declared entries
  after the codified contexts, and a codified entry wins a clash. Contexts that
  are live but not declared are still removed. We will not keep whatever happens
  to be live, because that would make any mistaken or drifted context permanent.
- **Fail closed:** if the declaration can't be read (anything except HTTP 404, which
  means "none declared") or is invalid, `code-quality` is not updated on that repo.
- **Audit in reverse:** the compliance audit reports a declared check that the live
  `code-quality` doesn't enforce from the declared app, and also reports an
  unreadable or invalid declaration.
- **Built per ADR-0004:** the merge, validation and comparison logic are pure
  functions in `scripts/lib/required-checks.sh` with bats tests, and the `gh`
  reads and writes stay in the scripts that call them.

We will not sanction a separate extra-checks ruleset (option B), and we will not
use classic branch protection for repo-specific checks.

## Consequences

- One mechanism (`code-quality`) carries every required check, and bypass actors
  match by construction, so no rule is needed to keep a second ruleset's actors
  in sync.
- A repo's merge gate now depends partly on a file in that repo. Anyone who can
  merge to the repo's default branch can add a required check. They can also
  remove a repo-declared one, but never a codified one, since the codified
  contexts are a floor. Changes to the declaration go through the repo's normal
  `pr-quality` review.
- A declared context that no job produces blocks every PR in that repo, which is
  the same risk the codified contexts carry. The standard says to declare only
  checks every PR produces.
- An invalid declaration stops the self-heal from updating `code-quality` on that
  repo until it's fixed. That's deliberate (fail closed), but drift in the
  codified contexts can then sit unconverged there. The audit reports the invalid
  file, so it doesn't go unnoticed.
- Repos already using a separate ruleset for extra checks have to migrate: declare
  the checks, let the applier run, then delete the ruleset.
- The applier makes one extra API read per repo, for the declaration.
