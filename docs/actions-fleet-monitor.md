# Actions Fleet Monitor

A reusable GitHub Actions workflow that dynamically discovers all non-archived repos in an org, all active workflows per repo, and collects run telemetry for each. Surfaces a fleet summary as a Step Summary and (on failure) a GitHub Issue. No external infrastructure required.

## What it measures

For each active workflow across every non-archived repo in the org:

| Signal | Detail |
|---|---|
| Total / success / failed / cancelled | Run counts over the lookback window |
| Failure rate | `failed / total` |
| Duration p50 / p95 | Computed from `created_at` → `updated_at` on completed runs |
| Status | `HEALTHY` / `WARNING` / `DEGRADED` / `CRITICAL` (see thresholds) |

The fleet summary table is sorted by severity so the worst performers appear first.

## Delivery

- **Step Summary** — fleet table written on every run; visible in the Actions UI without leaving GitHub.
- **GitHub Issue** — opened when any workflow has failed runs; see [Issue destination](#issue-destination) below.
- **Token usage (org-wide)** — each run also appends an Effective Tokens (ET) rollup to the Step Summary via `scripts/token_report.sh`, scanning token-usage artifacts across every repo. The weekly digest is delivered as a tracking-issue comment by `token-report.yml` — see [docs/token-report.md](token-report.md).

## Usage

The monitor runs automatically on a daily schedule from `.github-private`. No per-repo configuration needed — repos and workflows are discovered dynamically.

To trigger manually:

```bash
gh workflow run actions-fleet-monitor.yml \
  --repo petry-projects/.github-private \
  --field org=petry-projects \
  --field lookback_days=7
```

To invoke from another workflow:

```yaml
jobs:
  monitor:
    uses: petry-projects/.github-private/.github/workflows/actions-fleet-monitor.yml@main
    with:
      org: petry-projects
      lookback_days: '7'
    secrets: inherit
```

## Issue destination

Issue creation uses `github.token` with `context.repo`:

- **Scheduled / `workflow_dispatch`** — runs in `.github-private`; issues are created there.
- **`workflow_call` from another repo** — `context.repo` refers to the **caller's** repository; issues are therefore created in the caller's repo using the caller's `GITHUB_TOKEN`. Ensure the calling workflow grants `issues: write` permission.

## Inputs

| Input | Required | Default | Description |
|---|---|---|---|
| `org` | no | `petry-projects` | GitHub org to scan — all non-archived repos discovered automatically |
| `lookback_days` | no | `1` | Rolling window of run history to inspect |

## Environment variables (script)

| Variable | Source | Description |
|---|---|---|
| `GH_TOKEN` | `secrets.DON_PETRY_BOT_GH_PAT` | PAT with `actions:read` across the org — intentionally a PAT rather than `GITHUB_TOKEN` because the default Actions token lacks cross-org `actions:read` |
| `ORG` | workflow input | Target org |
| `LOOKBACK_DAYS` | workflow input | Lookback window |

## Thresholds

| Status | Condition |
|---|---|
| `HEALTHY` | 0% failure rate |
| `WARNING` | > 0% and ≤ 20% |
| `DEGRADED` | > 20% and ≤ 50% |
| `CRITICAL` | > 50% |
| `—` | No runs in the lookback window |

Thresholds are defined in `scripts/fleet_monitor.sh`.

## Known limitations

- **1,000-run cap per workflow**: The GitHub workflow-runs API returns at most 1,000 results per `created>=` query even with `--paginate`. High-frequency workflows with > 1,000 runs in the lookback window will have older runs silently omitted. Practical impact: at 1,000 runs over 7 days, that is ~143 runs/day, which only applies to event-driven workflows in large active repos.

## Linting

`shellcheck` and `bats` run on all PRs that touch `scripts/`, `.github/workflows/`, or `tests/` via `.github/workflows/lint.yml`.

## RFC

See [Discussion #193](https://github.com/petry-projects/.github-private/discussions/193) for the design discussion behind this monitor.
