---
artifact: brief
status: final
---

# Decision Brief — WidgetLint

- **Slug:** `widget-lint`
- **Source Discussion:** https://github.com/acme/widgets/discussions/413
- **Author / owner:** Mary (Analyst), decision-brief stage
- **Status:** `ready-for-decision`
- **Last updated:** 2026-10-19

## 1. Problem
Teams that ship widgets have no lint for widget manifests, so malformed manifests
reach production. The Discussion thread reports three incidents in Q3; the exact
rate across the org is unknown — needs discovery.

## 2. Target user & JTBD
- **Who:** maintainers of repos that publish widget manifests (the thread names two).
- **Job to be done:** When _I open a PR that touches a manifest_, I want to _see
  schema errors before review_, so I can _fix them without a production incident_.

## 3. Market & competitive context
Generic JSON-schema linters cover the shape but not the org's naming rules.
Market size for this niche is unknown — needs discovery. See `market-research.md`.

## 4. Opportunity → solution
See `ost.md`.
- **Desired outcome (metric):** manifest-caused incidents per quarter → 0
- **Opportunity addressed:** errors found only after merge
- **Proposed solution(s):** a CI lint step reusing the existing schema

## 5. Value & feasibility (rough)
- **Impact:** medium — three incidents in a quarter, per the thread.
- **Effort:** small — one reusable workflow step.
- **Prioritization score** — ICE:
  - Impact = 3/5, Confidence = 2/5 (thread evidence, no measured rate), Ease = 4/5
  - ICE = 3 × 2 × 4 = 24 / 125

## 6. Riskiest assumptions & cheapest test
| # | Assumption | If wrong… | Cheapest test | Result |
|---|-----------|-----------|---------------|--------|
| 1 | The three incidents were manifest-shape errors a lint would catch | the lint prevents nothing | re-read the three incident postmortems (1 hour) | — |

## 7. Recommendation (go / no-go)
**Recommendation: go** — small, grounded, reversible. A POC would need to prove the
lint catches the Q3 incident class. The decider should say no if the postmortems show
the errors were semantic, not structural. The decision is the human's, made by applying
`idea:approved` on the Discussion.

## 8. Open questions
- No brainstorm.md exists for this idea; the brief proceeded from the thread alone.
