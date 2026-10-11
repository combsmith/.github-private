# Seeding `repo-template` — operator procedure

`scripts/seed-repo-template.sh` writes the org baseline scaffold into
`petry-projects/repo-template` and opens one pull request there. No workflow runs
it. An operator runs it by hand, following this procedure, so the standards ref a
seed is generated from is predictable (#1925).

For what the scaffold contains and why the template must track standards, see
[AGENTS.md → Template drift guard](../../AGENTS.md#template-drift-guard-repo-template).

## When to seed

- After the standards channel is promoted (`standards/v1-stable` moved), so the
  template picks up the newly published content.
- When `template-drift` reports a file **DRIFTED** or **MISSING**.

Do **not** seed when `template-drift` reports **AHEAD**. The template already
carries newer standards content than the channel. Promote standards instead
(`scripts/cut-standards-release.sh` in `petry-projects/.github`).

## Before you start

- Run from a checkout of this repo at `main`.
- Run on Linux, or on macOS with GNU bash 5 and coreutils first on `PATH`. Stock
  macOS bash 3.2 cannot run the script.
- `gh` must be logged in with write access to `petry-projects/repo-template`.

## Which standards ref

Leave `STANDARDS_REF` unset. The script then resolves the published channel
`standards/v1-stable` and pins every read to that commit.

Set `STANDARDS_REF` only to reproduce or investigate a specific seed. Never set it
to seed the template ahead of the channel: the next channel-based seed would then
be a downgrade, which the script refuses.

## Steps

1. **Dry run.** It reads only and prints one decision per file.

   ```bash
   DRY_RUN=true bash scripts/seed-repo-template.sh --repo petry-projects/repo-template
   ```

2. **Read the plan.** Check the `standards ref:` line names the ref and commit you
   expect, then check each file's decision:

   | Decision | Meaning |
   |---|---|
   | `CREATE` / `UPDATE` | The file will be written. |
   | `REPLACE … DESTRUCTIVE` | The file will be written and gets shorter. Look at why before going on. |
   | `SKIP` | Already identical. |
   | `PRESERVE` | Owned by the consumer or by another managed process. Left alone. |
   | `REFUSE` | The template is ahead of the ref. Left alone. See below. |

3. **Seed.**

   ```bash
   bash scripts/seed-repo-template.sh --repo petry-projects/repo-template
   ```

4. **Review the pull request** it opens or updates on `repo-template`, then merge it
   there.

## What the run does with pull requests

- **One seed PR per repo.** If a `seed-scaffold/*` PR is already open, the run
  updates that PR's branch instead of opening another.
- **Older seed PRs are closed.** If several are open, the newest is kept. Each older
  one is closed with a comment linking the kept PR. If one cannot be closed, the run
  fails and names it.
- **The PR body states the provenance:** the resolved standards ref, how it was
  chosen (channel, explicit `STANDARDS_REF`, HEAD fallback, or a local
  `STANDARDS_DIR`), and the commit. A reused PR's body is rewritten on each run.
- **No PR for nothing.** If no file needs writing, no PR is opened.

## `REFUSE`: the standards channel is behind the template

A file is refused when it differs from this run's emission but matches the emission
at the standards default-branch HEAD. Writing the channel's version over it would
downgrade the template. The run leaves the file alone and warns:

> standards channel is behind the template — promote standards

Promote the channel, then seed again. If every differing file is refused, no PR is
opened.

If the script cannot tell whether a newer standards commit exists, or cannot compute
the emission at HEAD, it stops with an error instead of overwriting the file. Fix the
read (usually a `gh` login or rate-limit problem) and run it again.
