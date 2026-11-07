---
artifact: market-research
status: final
---

# Market Research — WidgetLint

- **Slug:** `widget-lint`
- **Last updated:** 2026-10-19

## How it's solved today
| Alternative | What it does well | Where it falls short | Pricing / model |
|-------------|-------------------|----------------------|-----------------|
| ajv-cli | fast schema validation | no org naming rules | free, MIT (https://github.com/ajv-validator/ajv-cli) |

## The gap / wedge
Nothing enforces the org's naming rules; the schema alone is not enough.

## Market signal
Internal only. Demand outside the org is unknown — needs discovery.
ajv has about 100 million weekly downloads [^1].

## Risks & unknowns
The schema may drift from the rules faster than the lint is updated.

## Sources
[^1]: https://www.npmjs.com/package/ajv
