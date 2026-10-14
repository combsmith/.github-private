# Pinned copy of the public token-budget consumer (round-trip fixture, #1565)

These files are a **verbatim pinned copy** of the shipped consumer that
`scripts/lib/usage-telemetry.sh` must feed, taken from
`petry-projects/.github` @ `b16e764a4bd52c7dd3baef3212f072aa58aeff97`:

- `agent-rate-limit.sh` — the public library (`scripts/lib/agent-rate-limit.sh`).
- `agent-rate-limits.json` — the public config (`standards/agent-rate-limits.json`), verbatim.
- `agent-rate-limits.armed.json` — the same config with `weekly_all.enabled=true`
  so the glide-path gate is exercisable (production ships it `false`/inert).

They exist so `tests/dev-lead/integration/test_usage_telemetry_roundtrip.bats`
(AC #7) proves the adapter's envelope is consumable by the **real** gates with no
live network. Refresh by re-copying from the public repo when that library's
envelope contract changes — a diff here is the intended drift signal.
