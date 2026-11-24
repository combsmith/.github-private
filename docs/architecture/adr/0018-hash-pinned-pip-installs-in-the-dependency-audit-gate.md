# 0018. Hash-pinned pip installs are enforced inside the dependency-audit gate

## Status

proposed

## Context

Six per-repo guards check pip installs in workflows, and each has a different gap.
Scorecard parses shell correctly but has its own blind spots:

- It sees only `pip`/`pip3`/`python -m pip` as the first words of a command, so it
  misses `retry pip install` and `pip --opt install`.
- It records a processing error, no finding, for a block it cannot parse, and it
  skips blocks that use other shells.
- It runs weekly, after merge.

Building from an sdist, or `-e` without `--no-build-isolation`, fetches build
requirements that are not hash-checked. A new reusable would bring ADR-0002's
channel, ring and ruleset overhead. `dependency-audit / Audit gate` is already
required, codified in `code-quality.json`, and audited through `REQUIRED_WORKFLOWS`.

## Decision

We will require every pip install in a workflow `run:` step to have `pip install`,
`pip3 install` or `python[3] -m pip install` as the subject of its parsed command (a
leading `sudo` is dropped). Each install must **also** take one of two forms:

- `--require-hashes --only-binary :all: -r <file>`, where any number of `-r` files is
  allowed and the path is free (`--only-binary=:all:` is accepted too); or
- `--no-deps --no-build-isolation -e <local path>`, whose build backend must already
  be installed from a hashed lock.

**What counts as an install attempt:** every parsed simple command whose words include
a pip word followed later by the word `install`. Both must be whole literal words. A
pip word is either a word whose basename matches `pip[0-9.]*`, or `-m pip` after a
`python*` word. Once a command counts as an attempt, its subject must be one of the
accepted subjects, otherwise it fails. `retry pip install …` is an attempt whose
subject is `retry`, so it fails. A command whose subject is `echo` or `printf` is not
judged.

A package listed in the repo's `.github/pip-source-builds.json` may add
`--no-binary <package>`, which must come after `--only-binary :all:` because pip applies
these options left to right and a later one overrides an earlier one, so the
per-package exception only takes effect after the general `:all:` restriction. It must
also carry `--no-build-isolation`. An entry is
approved by a code-owner review of the change to that JSON file.

We will enforce this inside `dependency-audit-reusable.yml` with a job that sits in
`audit-gate`'s `needs` and runs unconditionally, whether `detect.outputs.pip` is true
or false. The job has two parts:

- Scorecard `--local` Pinned-Dependencies, where only pip findings in workflow `run:`
  steps fail.
- A pure classifier with bats tests (ADR-0004) over shfmt's AST. It fails closed on
  unparseable blocks, and on blocks in a shell other than bash or sh that contain
  `pip` (or `pip3`) as a word. Other text that contains those letters, such as
  `pipeline` or `pipefail`, does not count.

The job lands in warn mode and switches to fail in a later release. No repo will keep
its own install-line parser.

## Consequences

- Pinning failures are reported under the context named "Audit gate".
- Unhashed installs, installs behind wrappers, installs with an option before
  `install`, and `-r` installs without `--only-binary` must be rewritten. That covers
  the two unhashed installs (broodly `ci.yml:188` and incubator `ci.yml:249`), the six
  `retry` installs (incubator `ci.yml:249` among them), and empower's `-r` installs.
- `--only-binary :all:` stays required, so the guards it replaces get no looser.
- The reusable gains two pinned binaries, Scorecard and shfmt.
- What the check does not catch:
  - pip reached through a variable, an alias, a function, or a `bash -c` or `eval`
    string;
  - how the build backend behind the `-e` form was installed: the classifier reads
    command text only and Scorecard does not cover a preinstalled backend, so a backend
    supplied by the runner image or an earlier non-pip step is not checked against a
    hashed lock. This is an accepted risk; the rule that it come from a hashed lock is
    a convention that the implementation issue may tighten;
  - scripts, composite actions and devcontainers;
  - npm, go and Dockerfiles, beyond what Scorecard writes to the job summary.
- Checks that are not about the install line stay in their repos, such as empower's
  lock coverage and bmad's npm lock check.
- `.github` gets no ring shielding, because it calls the reusable by local path.
- Nothing is implemented by this record. Sections 1-4 of the
  [advisory on combsmith/.github#1564](https://github.com/combsmith/.github/issues/1564#issuecomment-7086584330)
  are the acceptance criteria for a later implementation issue. Where they differ from
  this record, this record governs.
