---
artifact: brief
status: draft   # draft | final — the incubation gate requires `final`
---

# Decision Brief — <Idea Title>

<!--
The decision brief / PRD-lite. This is the artifact a human decides `idea:approved`
on. It exists to INFORM the go/no-go with discovery evidence — it does not replace
discovery, and it is not the full PRD (that gets written in the product repo after
graduation). Owner: Mary (Analyst). Keep it tight — a page or two.
-->

- **Slug:** `<slug>`
- **Source Discussion:** <link>
- **Author / owner:** <who>
- **Status:** `draft` → `ready-for-decision` → `approved` | `declined` | `parked`
- **Last updated:** <YYYY-MM-DD>

## 1. Problem
What pain, for whom, and why now? One paragraph. Evidence, not assertion.

## 2. Target user & JTBD
- **Who:** <primary user / segment>
- **Job to be done:** When _[situation]_, I want to _[motivation]_, so I can _[outcome]_.

## 3. Market & competitive context
How is this solved today (alternatives, competitors, workarounds)? What's the gap?
Link `market-research.md` for the detail; summarize the takeaway here.

## 4. Opportunity → solution
The bet, mapped onto the opportunity-solution-tree (`ost.md`):
- **Desired outcome (metric):** <what moves if this works>
- **Opportunity addressed:** <the customer need/pain this targets>
- **Proposed solution(s):** <the concept(s) under consideration>

## 5. Value & feasibility (rough)
- **Impact:** <low / med / high — and why>
- **Effort:** <t-shirt or rough weeks>
- **Prioritization score** — pick one and show the numbers:
  - RICE = (Reach × Impact × Confidence) / Effort = **<score>**
  - or ICE = (Impact × Confidence × Ease) / … = **<score>**

## 6. Riskiest assumptions & cheapest test
List the assumptions that would kill this if wrong, most-dangerous first. For the
top one or two, name the *cheapest* test (a spike, a fake-door, five interviews).
| # | Assumption | If wrong… | Cheapest test | Result |
|---|-----------|-----------|---------------|--------|
| 1 | | | | |

## 7. Recommendation (go / no-go)
The brief's own recommendation and *why* — but the decision is the human's, made by
applying `idea:approved`. State what a **POC would need to prove** to graduate.

## 8. Open questions
Anything unresolved that the decision-maker should know is unresolved.
