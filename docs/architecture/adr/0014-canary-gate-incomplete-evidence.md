# 0014. The canary gate signals incomplete evidence and never fakes it

## Status

proposed

## Context

The canary-rollout gate (`petry-projects/.github`, `scripts/canary-rollout.sh`
with its pure core `scripts/lib/canary-rollout.sh`) decides promotions from
GitHub run history: executed runs since a candidate's cut, failures since the
cut, and a 14-day baseline that sizes the sample a promotion needs. Every one
of those reads has a cap. A run listing returns at most 1,000 results when it
carries a search parameter. Attributing an ADR-0007 `agent-ingress.yml` run to
a role costs one jobs read per run, bounded by `CANARY_INGRESS_JOBS_MAX`
(default 300).

No recorded decision said what the gate does when a cap is hit. The
Solution Architect advisory on `petry-projects/.github#1244` (2026-10-11)
found each read had answered that question separately, and three answers were
wrong:

- The per-role reader accepted a capped list as complete. Measured that day,
  the newest 1,000 runs of `.github-private` "Dev-Lead Agent" reached back
  less than a day. Over a 5-day window the list showed 0 failures and a
  complete read showed 33.
- The baseline zero-filled the days a capped list never reached. For a
  workflow with 437 executed runs on its one visible day the pure sizing
  function returned the clamp minimum (3). From that day alone it returns the
  maximum (15).
- A truncated baseline read that observed nothing emitted a count of `1`, so
  the caller could not tell "unknown" from "one run".

ADR-0007's Consequences name the cost ("run attribution coarsens", "union
subscription starts more runs") and set no read budget. `markets`, the only
collapsed repo, produced 265 ingress runs in its first 7.3 days, 127 of them
in one day. Of the 265, 163 were cancelled, 93 succeeded, 8 were skipped and
1 failed. A jobs read takes about 0.8 s. A union ingress on `.github-private`
would pass 300 runs within hours, and because a candidate's window only
grows, a cap hit there cannot clear until the next cut.

ADR-0004 already says a pure path that cannot resolve its source stays inert
and emits `INDETERMINATE` "rather than fabricating a verdict". That ADR is
recorded for this repo's scripts. The gate lives in the sibling repo and
follows the same split by convention. This ADR records the rule for the gate
directly, so it no longer rests on a convention.

## Decision

We will treat a read the gate cannot prove complete as incomplete, say so in
the data it returns, and never substitute a count or a verdict for what was
not observed. The checkable boundaries:

- **One completeness rule for every capped run list.** A list under its cap
  is complete. A list at its cap is complete only when its oldest entry is
  strictly older than the window start. This is one pure function
  (`run_list_covers`) used by the per-role reader and both ingress call
  sites.
- **A gating window that is not complete is completed or held, never
  trusted.** The per-role reader completes it with the window's
  failure-class runs, read with a server-side status filter. The executed
  count is then a lower bound, which can only delay a promotion. If a
  failure-class list is itself truncated, or an ingress run cannot be
  attributed, the member is UNRESOLVED and the gate holds.
- **A baseline day the read did not reach is unknown, not zero.** The
  baseline is sized from the days actually observed.
- **"Unknown baseline" is an explicit signal, never a count.** When a
  truncated baseline read observed nothing countable, the sample is sized at
  its clamp **minimum** and is never waived as "no caller". Maintainer
  ruling, 2026-10-11, closing item 16 of `petry-projects/.github#1244`.
- **A verdict needs a comparison.** When the candidate commit is unresolvable
  the reusable was not compared, so the triage is `-` (indeterminate), not
  `PRE_EXISTING` and not `REGRESSION`. The pair stays BLOCKED.
- **Role eligibility is a property of the role, not of the member.** An
  agent with no `ingress_job` is not an ADR-0007 ingress role, so a member's
  ingress is never read for it and a member without its per-role workflow is
  a non-consumer. An agent with an `ingress_job` must be carried by every
  collapsed member's ingress, and a member that lacks the job is UNRESOLVED.
  CI lints the registry against the canonical `agent-ingress.yml` in both
  directions so a forgotten `ingress_job` fails before merge. We will not add
  a per-member exemption field: ADR-0007 declined per-repo, per-role
  narrowing, and an exemption is that lever.
- **The ingress read budget bounds uncached reads per sweep, not the size of
  the window.** We will persist the jobs of completed ingress runs across
  sweeps, keyed by run id and run attempt, and count only cache misses
  against `CANARY_INGRESS_JOBS_MAX`. We will keep the default at 300 and will
  not raise it as a substitute. This must land before a named ring member
  (`.github`, `.github-private`, or a `ring1` repo) is collapsed.

An expected outcome must not read as a failure. A busy repo, a quiet role, a
non-consumer and a tag that has not been cut yet are expected. Each bullet
above holds the gate only where evidence of a failure could be missing.

## Consequences

- A failure since the cut can no longer scroll out of the gate's view. Pairs
  that read clean on a truncated list will show their failures on the first
  sweep after the change, so some promotions that would have gone through
  will block.
- Busy agents are sized from observed days and reach the clamp maximum
  without a special case. At their volume that sample accumulates inside the
  dwell floor.
- **The clamp minimum for an unknown baseline accepts thin evidence on one
  narrow shape:** a role busy enough to deserve a larger sample whose runs
  are all older than the read reached. Health and dwell still gate that
  promotion. The maximum was rejected because a quiet role would then soak at
  15 indefinitely, and SOAKING opens no issue, so nobody would be told.
- **Persisting job reads adds state to a gate that keeps none today.** The
  state is evidence, not a decision: a cache miss costs a read and nothing
  else, and a lost cache is a slow sweep. It still needs a correct key. A
  re-run keeps its run id and replaces its jobs, so keying on the run id
  alone would serve stale conclusions. A run with no jobs recorded yet must
  not be cached.
- A cold cache on a busy collapsed repo takes several sweeps to fill, and
  the member is UNRESOLVED until it has. Collapsing a busy repo therefore
  holds its roles' promotions for the first sweeps, by design.
- The per-role reader makes up to two more list calls per member and
  workflow, only when the general list is truncated for the window.
- Moving the "forgotten `ingress_job`" guard from run time to CI means the
  gate trusts the committed registry. A registry edited outside CI could
  make a collapsed role read as "no caller".
- The gate still detects a collapsed repo from a workflow record, which a PR
  branch can create without the ingress file ever reaching the default
  branch (`.github-private` carries such a record from 2026-09-13). After
  this decision that only matters for an ingress role with no per-role
  workflow on that member. Detecting collapse from the default-branch file
  is left as a separate change.

## References

- ADR-0004 (pure logic plus bats): "Fail Loud, Never Fake", the principle
  this applies to the gate.
- ADR-0007 (one agent-ingress stub per repo): the attribution cost this
  budgets, and the per-repo, per-role narrowing it declined. Not superseded.
- ADR-0010 (ingress job-level concurrency, exhaustive schema): keeps
  `continue-on-error` out of the ingress, which the attribution rules rely
  on.
- ADR-0002 (channel-tag releases and rings): the promotion this gate guards.
- `petry-projects/.github#1244`: the tracker, the Solution Architect advisory
  of 2026-10-11 and its measurements.
- `petry-projects/.github#1312` (per-role list completeness),
  `petry-projects/.github#1314` (indeterminate triage, issue #1249),
  `petry-projects/.github#1315` (non-ingress roles, issue #1247): the
  changes that implement every bullet except the read budget.
- `petry-projects/.github#548`: the gate standard the sample sizing comes
  from.
