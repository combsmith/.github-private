# LSP Pilot — Scoping Doc

**Status:** Contract — the single agreed definition of done that every later story in
epic [#839](https://github.com/combsmith/.github-private/issues/839) grounds in.
**Author:** dev-lead / Claude Code
**Date:** 2026-06-20
**Story:** [#840](https://github.com/combsmith/.github-private/issues/840) (Phase 1)
**Scope (confirmed from discussion [#578](https://github.com/combsmith/.github-private/discussions/578)):**
Pilot Language Server Protocol (LSP) code intelligence as MCP tools in the **pr-review**
agent, **Shell** language, **this repo**, scoped to **finding-verification** in the
deep/audit tiers — measured against a frozen baseline for a human go/no-go.

This doc is the contract, not a vendor survey: it fixes the pilot's language, the specific
agent actions it covers, the cold-start SLA, the success metric, the cost cap, and the
candidate-server shortlist so the downstream wiring and measurement stories
([#841](https://github.com/combsmith/.github-private/issues/841)–[#846](https://github.com/combsmith/.github-private/issues/846))
share one unambiguous scope instead of each re-deciding it. It **reuses**, and does not
re-describe, the MCP mechanism that already shipped (epic
[#676](https://github.com/combsmith/.github-private/issues/676); see §6).

---

## 1. Scope — language, repo, tier

| Dimension | Pilot decision |
|---|---|
| **Target language** | **Shell** (bash) |
| **Pilot repo** | **`.github-private`** (this repo) |
| **Agent surface** | **pr-review** only |
| **Review tiers** | **deep / audit** only (the agentic tiers); triage is never touched |

**Rationale (tied to the discussion).** Shell in `.github-private` is the agent's own
substrate — the harness's biggest "language" is itself (`scripts/engine.sh`,
`scripts/review-batch.sh`, the audit scripts), so the pilot reviews code it already owns
with no cross-repo coordination. `bash-language-server` is lightweight (Tree-sitter based,
near-instant index for a shell-only repo), which keeps cold-start off the critical path —
the make-or-break operational risk for LSP on ephemeral CI runners. pr-review
finding-verification is the lowest-risk first surface: a bad verification only downgrades a
finding, whereas a bad code write breaks a build (so dev-lead code-writing is deferred —
see §2).

---

## 2. In-scope vs out-of-scope agent actions

**In scope — finding-verification in the deep/audit tiers.** LSP is used as a
*grounding/verification* step: before the reviewer posts a cross-file claim, it confirms the
claim against real semantic context via:

- **find-references** (`textDocument/references`) — confirm "this breaks N callers" /
  "this symbol is unused" against the actual reference set, not a textual `grep` match.
- **diagnostics** (`textDocument/publishDiagnostics`) — confirm "this is undefined / this is
  a type or syntax error" against the language server's own diagnostics.

This directly attacks the false-positive problem (textual `grep` matches a name in a string
or comment; LSP resolves the *semantic* reference), which is what erodes trust in an
auto-approving reviewer.

**Explicitly OUT of scope for this pilot:**

- **The triage tier.** Triage stays fast and restricted; it never receives MCP/LSP tools
  (consistent with the existing per-tier gating — see §6).
- **dev-lead code-writing.** LSP-assisted code *authoring/fixing* (safe `rename`,
  `definition`-on-first-pass, pre-push `diagnostics`) is **not** part of this pilot. It is
  considered only after a positive go/no-go on the pr-review surface (epic Phase 3,
  [#845](https://github.com/combsmith/.github-private/issues/845)).

---

## 3. Cold-start SLA & graceful degradation

**SLA:** LSP cold-start (server launch + index to query-ready) must complete in
**<=30s P95** on the pilot repo.

**Auto-skip rule (graceful degradation).** If cold-start exceeds the SLA, the LSP step is
**automatically skipped — never a workflow failure**. The review continues on the model's
base capabilities (and the existing `grep`/read navigation) and the run's verdict and exit
code are untouched. Exceeding the SLA degrades the *enrichment*, not the *review*.

This is an **addition layered on** the MCP graceful-degradation path that already exists in
`scripts/engine.sh` (`_emit_mcp_failure_warning` emits a single `::warning::[mcp]`
annotation on a server connect/init failure and leaves the verdict and exit code intact — see
§6 and `docs/initiatives/mcp-powered-review.md` §4), not a replacement for it. The SLA
auto-skip is the same "Fail Loud, Never Fake" contract applied to the new cold-start budget:
skip visibly, continue, never abort. Cold-start measurement and the SLA enforcement /
index-caching live in story
[#846](https://github.com/combsmith/.github-private/issues/846); this doc only fixes the
SLA number and the auto-skip policy.

---

## 4. Success metric & cost cap

These are transcribed verbatim from the epic
([#839](https://github.com/combsmith/.github-private/issues/839)) body so the doc and
the epic stay one source of truth. If the epic changes, update this section to match.

### Initiative success metric

> Go = on the **frozen pilot PR corpus**, LSP-on deep-tier review delivers a **measurable
> navigation-token reduction (target >=2x fewer navigation tool-call tokens vs the LSP-off
> control)** AND **no regression in review quality** (false-positive / precision **no worse
> than the frozen LSP-off baseline**), achieved **within the cold-start SLA (<=30s P95)**. A
> win on tokens that costs precision is a *no-go*, not a win.

The frozen corpus and the immutable LSP-off baseline are established in story
[#841](https://github.com/combsmith/.github-private/issues/841).

### Cost cap (explicit)

> - LSP is gated to **deep/audit tiers only** (triage untouched); cold-start is
>   **auto-skipped above the 30s P95 SLA** (graceful degradation, never a workflow failure).
> - The pilot is run-count bounded: **<=20 PRs in the corpus x <=2 candidate servers x <=3
>   runs each ~= <=120 deep-tier review runs total**, under the existing 60-min job cap. No
>   fleet-wide rollout, and no dev-lead (code-writing) LSP, until the go/no-go decision
>   record lands.

The cost cap is structural (run-count and tier-gating), not a dollar ceiling.

---

## 5. Candidate LSP-MCP servers & selection rule

Three candidate LSP-MCP servers are compared in the pilot. **Final selection is decided by
the comparative pilot ([#844](https://github.com/combsmith/.github-private/issues/844))
on the frozen corpus — it is NOT pre-chosen here.** Per
[@don-petry](https://github.com/combsmith/.github-private/discussions/578) the choice is
made from measured **speed, quality, and cost** with and without LSP, not from the vendor
narrative.

| Candidate | Distribution | Notes (from research, [#578](https://github.com/combsmith/.github-private/discussions/578)) |
|---|---|---|
| **agent-lsp** ([blackwell-systems/agent-lsp](https://github.com/blackwell-systems/agent-lsp)) | Single Go binary (pin a GitHub release tag) | Persistent daemon (~10s first index), `--non-interactive` + `--http` CI modes, GCF token compression, 30-language CI matrix. CI-first design. |
| **Serena** ([oraios/serena](https://github.com/oraios/serena)) | Python wheel via `uv` (pin an exact PyPI version) | Has the production benchmark (Project AEGIS); use its results as the bar to beat. |
| **lsp-mcp** ([owner/lsp-mcp](https://github.com/owner/lsp-mcp)) | Go binary (pin a GitHub release tag) | ~24 tools, CI-verified across several languages. |

All three drive the same underlying Shell language server, **`bash-language-server`** (npm),
which is **also pinned** to an exact version for the pilot.

### Version-pinning rule

Each candidate (and `bash-language-server`) is a **third-party, non-org-owned dependency**
and **must be pinned to an exact version for a reproducible pilot** (epic untracked
prerequisite). The exact pins are **locked when the server is wired** (story
[#842](https://github.com/combsmith/.github-private/issues/842)) and recorded back into
the table below — they are not invented in this scoping doc, consistent with the repo rule
that pins (SHAs / release tags) are looked up from the source of truth, never guessed
([CLAUDE.md](../CLAUDE.md), [AGENTS.md](../AGENTS.md)).

| Dependency | Source of truth | Pinned version | Locked in |
|---|---|---|---|
| agent-lsp | GitHub releases — `blackwell-systems/agent-lsp` | *to be locked* | #842 |
| Serena | PyPI / `oraios/serena` releases | *to be locked* | #842 |
| lsp-mcp | GitHub releases — `owner/lsp-mcp` | *to be locked* | #842 |
| bash-language-server | npm `bash-language-server` | *to be locked* | #842 |

Only the candidate that wins the comparison is carried past Phase 2; the run-count cost cap
in §4 bounds the comparison to **<=2 candidate servers**.

---

## 6. How this rides the existing MCP plumbing (reuse, do not rebuild)

LSP is **one more MCP server behind the knob that already shipped** — the pilot does not
rebuild the gating, the graceful-degradation path, or the Token Cost Observatory.

- **Per-tier gating + config threading.** `scripts/engine.sh` already threads
  `--mcp-config <file> --strict-mcp-config` and the merged `--allowed-tools` into the
  agentic tiers (`run_agentic` — deep/audit) and the rubber-duck tier (`run_duck`) via
  `REVIEW_MCP_CONFIG` / `REVIEW_MCP_ALLOWED_TOOLS`; the fast triage tier is intentionally
  excluded. This pilot scopes LSP *use* to the deep/audit finding-verification surface (§2).
  The LSP server is added as another entry in the same MCP config and its tools as another
  `REVIEW_MCP_ALLOWED_TOOLS` glob. See
  [`docs/initiatives/mcp-powered-review.md`](./initiatives/mcp-powered-review.md) §3 for the
  knob and [`.github/review-mcp.json`](../.github/review-mcp.json) for the live MCP config
  (Context7 today).
- **Graceful degradation.** The MCP "Fail Loud, Never Fake" path
  (`_emit_mcp_failure_warning` in `scripts/engine.sh`) already turns an unavailable server
  into a single `::warning::[mcp]` annotation while the review completes on base
  capabilities. The §3 SLA auto-skip is layered on top of this, not a parallel mechanism.
  See [`docs/initiatives/mcp-powered-review.md`](./initiatives/mcp-powered-review.md) §4.
- **What is genuinely new in this initiative:** (a) the cold-start SLA + index-caching +
  auto-skip on the LSP server's launch budget (#846), and (b) the finding-verification step
  that calls find-references / diagnostics before posting a cross-file finding (#843).

---

## 7. References

- Epic [#839](https://github.com/combsmith/.github-private/issues/839) — LSP pilot;
  stories #840 (this doc), #841 (corpus + baseline), #842 (wire server), #843
  (finding-verification step), #844 (run comparison), #845 (go/no-go), #846 (cache + SLA).
- Discussion [#578](https://github.com/combsmith/.github-private/discussions/578) —
  idea body, the LSP-MCP server-selection weekly update, and the enhancement comment whose
  suggested `docs/lsp-pilot.md` this mirrors.
- [`docs/initiatives/mcp-powered-review.md`](./initiatives/mcp-powered-review.md) — the MCP
  knob (§3) and graceful degradation (§4) this pilot reuses.
- [`scripts/engine.sh`](../scripts/engine.sh) — `REVIEW_MCP_CONFIG` /
  `REVIEW_MCP_ALLOWED_TOOLS` threading and `_emit_mcp_failure_warning`.
- [`.github/review-mcp.json`](../.github/review-mcp.json) — live MCP config.
- [`.github/workflows/pr-review.yml`](../.github/workflows/pr-review.yml) — the review
  workflow that invokes the engine.
