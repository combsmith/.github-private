---
artifact: ost
status: draft   # draft | final — supporting artifact (not gate-required)
---

# Opportunity–Solution Tree — <Idea Title>

<!--
Teresa Torres's opportunity-solution-tree, rendered as Mermaid (GitHub renders it
natively — no whiteboard tool needed). Structure: one desired OUTCOME → the
OPPORTUNITY space (customer needs/pains) → the SOLUTION space → ASSUMPTION tests.
A living document — revisit as you learn. Owner: Mary (Analyst).
-->

- **Slug:** `<slug>`
- **Last updated:** <YYYY-MM-DD>

```mermaid
flowchart TD
    O["🎯 Outcome: <metric that moves if this works>"]

    O --> OPP1["Opportunity: <customer need / pain #1>"]
    O --> OPP2["Opportunity: <customer need / pain #2>"]

    OPP1 --> S1["Solution: <concept A>"]
    OPP1 --> S2["Solution: <concept B>"]
    OPP2 --> S3["Solution: <concept C>"]

    S1 --> A1["Assumption test: <cheapest experiment>"]
    S2 --> A2["Assumption test: <cheapest experiment>"]
    S3 --> A3["Assumption test: <cheapest experiment>"]
```

## Notes
- **Outcome** is a metric, not a feature. Everything below serves it.
- Prefer breadth in the opportunity space before committing to a solution.
- Each solution should bottom out in the *cheapest* test that could invalidate it.
