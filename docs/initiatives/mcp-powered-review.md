# Initiative: MCP-Powered CI Review Enrichment

**Status:** Reference — recommended server set + enablement knob (Phase 2 of epic [#676](https://github.com/petry-projects/.github-private/issues/676))
**Author:** dev-lead / Claude Code
**Date:** 2026-06-14
**Scope (confirmed):** The self-hosted Claude review engine (`scripts/engine.sh`, invoked by
`pr-review.yml`). Covers (a) which MCP servers to recommend per downstream stack, and (b) how to turn
MCP-enriched review on via the engine knob. Does **not** change default review behavior — MCP is
strictly opt-in and inert when unconfigured.
**Constraints (confirmed):** GitHub-native + the existing engine only — no new infrastructure. MCP is
opt-in via committed env knobs (no thin-caller workflow edit required). Security-first: a downstream
pilot happens **only after** the in-flight security-hardening work lands. Claims about server
availability are grounded in discussion [#650](https://github.com/petry-projects/.github-private/discussions/650)
(body + the 2026-06-13 weekly update) and must not overstate maturity.

---

## 1. Why MCP-enriched review

Reviews today draw solely on the model's training data, which can lag the latest library releases by
months — risking missed breaking changes and deprecated-API patterns. Downstream repos span **React,
Python, and Go**, so framework-specific, version-aware review benefits from live context. MCP (Model
Context Protocol) servers let a review pull **real-time** documentation and external security/quality
signal at review time instead of relying on stale training data alone.

This work delivers the MCP *plumbing* (the engine knob + graceful degradation) independently of the
broader review-engine rework tracked in epic [#610](https://github.com/petry-projects/.github-private/issues/610)
(generalize `pr-review` into a context-adaptive review agent). The MCP knob lands on its own so it does
not wait on the artifact-contract changes in #610.

---

## 2. Recommended servers per stack

Pick the smallest server set that covers the stack. Context7 is the lowest-friction starting point for
any stack (free, stateless, no authentication); the GitHub and SonarQube servers add
security/quality signal on top.

| Server | What it adds | Auth / cost | Maturity (per #650, 2026-06-13) | Best fit |
|---|---|---|---|---|
| **Context7** | Real-time library/framework documentation; catches deprecated APIs and breaking changes that static training data misses | Free, stateless, **no auth** | Available; lowest failure surface | **All stacks** — React (component/library docs), Python (package docs), Go (module docs) |
| **GitHub MCP — secret scanning** | Scans for exposed secrets during agent code generation, honoring repo/org push-protection settings | `GITHUB_TOKEN` (no PAT); integrates with existing repo security settings | **GA (May 2026)** | Any stack; security-sensitive repos |
| **GitHub MCP — dependency scanning** | Flags vulnerable dependencies before merge (repos with Dependabot alerts enabled) | `GITHUB_TOKEN`; Dependabot alerts enabled | **Public preview** (not GA) | Any stack with a dependency manifest |
| **SonarQube MCP** | Enriches review with existing code-quality data (smells, coverage, hotspots) | SonarQube instance + token | Available where a SonarQube project exists | Repos already running SonarQube |

> **Availability caveat.** GitHub MCP **secret scanning is GA**; **dependency scanning is public
> preview**, not GA. Do not represent the preview surface as production-ready.
>
> **Plan caveat for this repo (#816).** GitHub MCP secret scanning's `run_secret_scanning` tool is a
> content-scan API gated on the repository's **`advanced_security`** flag (full GitHub Advanced
> Security) — a *different* flag than Secret Protection / push protection — and that flag is **not
> available on this private repo's plan** (confirmed identically from two independent tokens). So on
> `.github-private` the GitHub-MCP secret-scanning starter only ever emits an "unavailable" degradation
> warning; the **actual pilot starter here is Context7** (zero-auth). Interim secret coverage stays
> intact via the existing `Secret scan (gitleaks)` CI check. See §5.

Suggested per-stack starters:

- **React / TypeScript** — Context7 (library docs) + GitHub MCP secret scanning.
- **Python** — Context7 (package docs) + GitHub MCP secret scanning + dependency scanning (preview).
- **Go** — Context7 (module docs) + GitHub MCP secret scanning; add SonarQube MCP where a SonarQube
  project already exists.

---

## 3. The engine knob (how to turn MCP review on)

MCP review is enabled by two environment variables read by `scripts/engine.sh`. Both are **opt-in**:
when `REVIEW_MCP_CONFIG` is unset, empty, or points at an unreadable path, the engine threads **no**
MCP flags and the review behaves byte-for-byte as before.

| Env var | Purpose |
|---|---|
| `REVIEW_MCP_CONFIG` | Path to an MCP-servers JSON config file. When set to a readable file, the engine appends `--mcp-config <file> --strict-mcp-config` to the Claude call. `--strict-mcp-config` means **only** the servers in this file are used (ambient MCP config is ignored). |
| `REVIEW_MCP_ALLOWED_TOOLS` | Comma-separated MCP tool globs (e.g. `mcp__context7__*`) merged into the per-tier `--allowed-tools` list so the model may actually invoke the server's tools. |

**Which review tiers get MCP.** The flags are threaded into the **agentic (deep)** and **rubber-duck**
Claude tiers only. The **triage** tier stays fast and restricted (it uses `--disallowed-tools` only and
never receives MCP flags), so the cheap first-pass is unaffected.

The base allowed-tools list for the MCP-eligible tiers is `Bash,Read,Grep,Glob`. When
`REVIEW_MCP_ALLOWED_TOOLS` is set, it is appended to that base; when it is unset, the base list is used
unchanged.

### 3.1 Worked example — Context7

1. Commit an MCP config file (path is what `REVIEW_MCP_CONFIG` points at), e.g.
   `.github/mcp/context7.json`:

   ```json
   {
     "mcpServers": {
       "context7": {
         "command": "npx",
         "args": ["-y", "@upstash/context7-mcp"]
       }
     }
   }
   ```

2. Set the two knobs in the review environment (committed config; no thin-caller workflow edit needed):

   ```bash
   REVIEW_MCP_CONFIG=.github/mcp/context7.json
   REVIEW_MCP_ALLOWED_TOOLS=mcp__context7__*
   ```

3. With both set, the engine invokes the Claude agentic/duck tiers with:

   ```
   --mcp-config .github/mcp/context7.json --strict-mcp-config \
   --allowed-tools Bash,Read,Grep,Glob,mcp__context7__*
   ```

   The triage tier is untouched. Unset both knobs and the call reverts to
   `--allowed-tools Bash,Read,Grep,Glob` with no MCP flags.

---

## 4. Graceful degradation — Fail Loud, Never Fake

When MCP is configured and a server is unavailable, the review **degrades visibly and continues** — it
never aborts the run and never fabricates an "all clear" verdict. Concretely, the engine:

- emits a single GitHub Actions warning annotation, naming the affected server(s) when it can extract
  them, e.g.:

  ```
  ::warning::[mcp] server(s) unavailable: context7 — review continues on the model's base capabilities (no MCP tool context)
  ```

  (when no server name can be parsed, a generic `::warning::[mcp] an MCP server was unavailable …`
  is emitted instead);
- leaves the model's verdict and the caller's exit code **untouched** — the review completes on the
  model's base capabilities, just without the MCP-sourced context;
- is **inert when MCP was never configured**: with `REVIEW_MCP_CONFIG` unset, no MCP warning is ever
  emitted, even if unrelated text in the output resembles a failure marker.

This means an unreachable MCP server costs you the *enrichment*, not the *review*. The behavior is
implemented in `scripts/engine.sh` (`_emit_mcp_failure_warning`) and regression-tested in
`tests/dev-lead/unit/test_engine_mcp.bats`.

---

## 5. Security-first sequencing & the revised starter

**Sequencing.** The organization's immediate priorities are security hardening (action allowlisting,
input sanitization). A downstream MCP pilot ([#681](https://github.com/petry-projects/.github-private/issues/681))
happens **only after** that in-flight security work lands — not before.

**Revised starter recommendation (2026-06-13 weekly update).** The original #650 proposal (2026-05-29)
suggested starting with either Context7 or GitHub MCP secret scanning. The 2026-06-13 weekly update
revised this toward **GitHub MCP Server (secret + dependency scanning)** as the lowest-risk first step,
on the reasoning that secret scanning was GA, required no auth beyond `GITHUB_TOKEN`, and integrated
with existing repo security settings.

**Outcome of the Phase-2 pilot (#681 → #816): the GitHub-MCP starter is plan-gated here; Context7 is
the actual pilot starter.** The MCP plumbing was proven end-to-end — #809's env-mapping fix landed, so
`REVIEW_MCP_ALLOWED_TOOLS` reaches the live job env, the GitHub MCP server connects, and its tools are
reachable. But the recommended `run_secret_scanning` tool is a content-scan API gated on the repo's
**`advanced_security`** flag (full GitHub Advanced Security) — a *different* flag than Secret Protection
/ push protection — and **that flag is not available on this private repo's plan** (confirmed
identically from two independent tokens). Keeping the GitHub entry configured therefore only emits an
"unavailable" degradation warning on every review. #681 closed **not-planned** on that starter, and
both the pilot doc and #681's AC #1 already named **Context7 as the zero-auth fallback**. #816 executes
that path:

- `.github/review-mcp.json` now configures the **zero-auth Context7 HTTP endpoint**
  (`https://mcp.context7.com/mcp`, `"type": "http"`) instead of the plan-blocked github/secret-scanning
  server. No `npx` install and no secret are needed — the remote endpoint is zero-install and zero-auth.
  (Restore the github entry later if/when `advanced_security` is licensed.)
- The repo variable `REVIEW_MCP_ALLOWED_TOOLS` is set to `mcp__context7__*`, permitting Context7's
  tools. The live server exposes exactly two tools — `mcp__context7__resolve-library-id` and
  `mcp__context7__query-docs` (verified via a direct `tools/list` JSON-RPC call, 2026-06-20). The
  wildcard covers both; do **not** pin individual tool names (an earlier draft referenced a
  `get-library-docs` tool that the server does not expose). Context7 accepts an optional
  `CONTEXT7_API_KEY` header for higher rate limits, but zero-auth is the point of this pilot — no
  secret is added.
- Interim secret coverage stays intact via the existing `Secret scan (gitleaks)` CI check.
- Graceful degradation is unchanged: if Context7 is unreachable the review still completes and emits a
  single `::warning::[mcp]` annotation naming the server (see §4; regression-tested in
  `tests/dev-lead/unit/test_engine_mcp.bats`).

> **Net guidance:** on this repo the *pilot* starter is **Context7** (zero-auth library/framework docs),
> because the GitHub-MCP secret-scanning starter is plan-gated (`advanced_security` unavailable). For
> *broad per-stack enrichment* afterward, Context7 remains the lowest-friction add for every stack; add
> GitHub MCP secret scanning once `advanced_security` is licensed.

### 5.1 Pilot enablement & rollout recommendation (#816)

**What this change establishes.** The config + allowlist are now in place: `.github/review-mcp.json`
points at the zero-auth Context7 endpoint and `REVIEW_MCP_ALLOWED_TOOLS=mcp__context7__*` permits its
tools. Because #809's env-mapping fix already proved the allowlist reaches the live job env and a
`"type": "http"` MCP server connects, Context7 connects and its tools are **permitted** (no "not
permitted" errors).

#### Evaluation (2026-06-20)

A controlled A/B was run **locally** (not via the `pr-review/stable` CI path, which is still pinned to
the pre-Context7 config — promoting `stable` is the production rollout and stays a human decision). The
eval replicated `engine.sh`'s deep-tier invocation exactly (`--mcp-config .github/review-mcp.json
--strict-mcp-config --allowed-tools "…,mcp__context7__*"`, model `claude-opus-4-8`), isolating Context7
as the single variable: three inlined PR diffs reviewed **off** (no tools) vs **on** (Context7 only).
Samples: (A) a TanStack Query v4→v5 upgrade with v4-only `useQuery` options; (B) a Pydantic v1→v2 bump
written against the v1 API; (C) a control with a pure-logic bug and no third-party dependency.

| Check | Result |
| --- | --- |
| **Connectivity / tools permitted** (AC #2 analog) | ✅ `resolve-library-id` + `query-docs` both connect; `tool_result.is_error=false` on every call; correct grounded answer ("`cacheTime` → `gcTime`") with doc citation. |
| **Graceful degradation** | ✅ Unreachable endpoint → review still completes on base capability (rc=0), ~no latency. |
| **Spontaneous adoption** | ✅ Both library PRs invoked Context7 under a **neutral** prompt (no nudge). The control PR used **zero** tools — the agent correctly skips docs when no library is involved. |
| **Correctness delta (off vs on)** | **None.** Both arms caught the same issues: A — 3 BLOCKERs (`cacheTime`→`gcTime`, `keepPreviousData` removed, `useQuery` `onSuccess`/`onError` removed); B — the HIGH `allow_mutation`→`frozen` silent-immutability regression + the v1-deprecation cluster; C — the same 3 logic bugs. On B the **off** arm was marginally *more* precise (it gave the `validate_default=True` nuance the non-nudged on-arm dropped). |
| **What Context7 added** | Auditable **grounding** (on-arms cite the actual migration guide) and slightly broader migration-sweep advice — but no net-new finding and no changed verdict. |
| **Cost when used** | +~30 s latency and ~2–4× token cost per library review (2–3 doc round-trips). On the control: **parity** (29 s on vs 32 s off, cost flat) — zero overhead when irrelevant. |
| **Nudging ("consult docs")** | More citations and one recovered detail, but more tool churn/latency (up to ~120 s, one arm wandered into `Bash`) and a minor new imprecision. Not worth a prompt change — spontaneous adoption already captures the value. |

**Interpretation.** The plumbing works end-to-end and the agent uses Context7 with good judgment, but the
measured *review-quality* lift on **mainstream** libraries is ≈0, because the base model's knowledge
(cutoff Jan 2026) already covers these versions. Context7's real marginal value concentrates where the
base model is weak: (a) library releases **after** the training cutoff, (b) **long-tail / private**
libraries, and (c) exact-signature precision + auditable citations / hallucination reduction. This
repo's own PR profile (mostly Bash/YAML) rarely hits those, so the local quality signal here is a
floor, not a ceiling.

**Latency (AC #4).** Measured directly from the eval (stream-json `duration_ms`): library reviews
+~30 s with Context7 on; non-library reviews unchanged. Live run durations can be monitored directly
via GitHub Actions run history once Context7 reaches the `stable` CI path — note that
`scripts/pr_review_health.sh` focuses on failure analysis (it exits early on all-green runs and only
downloads/analyzes failed-run logs), so it does **not** compile latency deltas for successful runs.

**Rollout recommendation.** Keep Context7 wired on `.github-private` — it is **zero-cost when
irrelevant** (the agent skips it) and adds **auditable grounding** when a PR touches a dependency. The
cost/benefit is favorable enough to **promote it to `pr-review/stable`** so live reviews exercise it;
but set expectations honestly — on this repo's Bash/YAML-heavy PRs the quality lift will be near-zero,
and the strong case is repos with heavy third-party-library churn (especially post-cutoff or long-tail
deps). **Promoting `stable` and any broader rollout to downstream repos stays a separate, explicit
human decision.** Revisit the GitHub-MCP secret-scanning starter only if/when the repo's plan gains
`advanced_security`.

---

## 6. References

- Discussion [#650](https://github.com/petry-projects/.github-private/discussions/650) — proposal body
  - 2026-06-13 weekly update (server availability + revised starter).
- Epic [#676](https://github.com/petry-projects/.github-private/issues/676) — MCP-powered review
  enrichment; stories #677 (engine knob), #678 (graceful degradation), #679 (workflow surface),
  #680 (this doc), #681 (downstream pilot).
- Epic [#610](https://github.com/petry-projects/.github-private/issues/610) — broader context-adaptive
  review-engine rework (MCP plumbing lands independently of this).
- `scripts/engine.sh` — `REVIEW_MCP_CONFIG` / `REVIEW_MCP_ALLOWED_TOOLS` threading and
  `_emit_mcp_failure_warning`.
- `tests/dev-lead/unit/test_engine_mcp.bats` — knob-threading + graceful-degradation tests.
- `docs/initiatives/agentic-release-strategy.md` — initiative-doc header shape.
