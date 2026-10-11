# Commercial Support & Enterprise Services Standard

Standard guidelines and canonical language for offering commercial support, enterprise
service-level agreements (SLAs), custom development, and commercial licensing across
repositories in the **petry-projects** organization.

---

## Purpose & Scope

All repositories in the `petry-projects` organization are open source by default (under MIT,
Apache 2.0, or AGPL). While software is freely available for community use, commercial entities
deploying these tools in production environments often require guaranteed response times, upstream
patch prioritization, custom integrations, or proprietary licensing exemptions.

Commercial support, enterprise integration services, and proprietary licensing for `petry-projects`
repositories are operated and provided through **CombSmith LLC**.

This standard defines:

1. The canonical **Commercial Support & Enterprise Services** markdown block required or recommended
   for repository `README.md` files.
2. The standard commercial pricing and service tiers.
3. Guidelines for package metadata and contact routing.

---

## Canonical README Section

Repositories publishing libraries, CLIs, Model Context Protocol (MCP) servers, or agent tooling
should include the following standard section in their `README.md` (typically placed directly before
the `Contributing` or `License` section):

```markdown
## 💼 Commercial Support & Enterprise Services

This project is open source and free for the community. For enterprise deployments, proprietary integration, and priority service, commercial support and custom engineering are provided through [CombSmith LLC](https://combsmith.com):

- **Standard SLA & Priority Support:** $199/month per organization
  - Guaranteed 24-hour issue triage
  - Dedicated private communications channel
  - Upstream bug-fix and security patch prioritization
- **Custom MCP Development & Architecture Advisory:** $250/hour
  - Custom tool, prompt, and resource connector implementation
  - Security audit and containerized deployment assistance
  - Tailored agentic workflow integration

For commercial invoicing, custom service agreements, or enterprise purchase orders, contact **support@combsmith.com** or visit [combsmith.com](https://combsmith.com).
```

---

## Standard Commercial Offerings & Rate Card

| Tier / Service | Price | Deliverables | Target Audience |
| :--- | :--- | :--- | :--- |
| **Community / FOSS** | Free ($0) | Public issue tracker, community PR reviews, open-source license | Individual developers, hobbyists, evaluators |
| **Standard SLA & Priority Support** | $199 / month | 24-hour initial response SLA on issues, private Slack/Discord channel, prioritized upstream patch releases | Startups and teams running petry-projects tooling in CI/CD or production |
| **Custom Engineering & Architecture Advisory** | $250 / hour | Custom tool connector implementation, security audits, infrastructure deployment, agent workflow design | Enterprises integrating custom proprietary data sources, MCPs, or internal workflows |
| **Commercial / Dual-Licensing** | Custom quote | Exemption from copyleft provisions (e.g., AGPL), custom warranties, indemnification | Organizations embedding libraries into closed-source proprietary commercial software |

---

## Repository Adoption Guidelines

When adopting this standard in a `petry-projects` repository:

1. **README Placement**: Insert the canonical markdown section above before the `License` heading.
2. **Package Metadata**:
   - For Python (`pyproject.toml`):

     ```toml
     [project.urls]
     "Commercial Support" = "https://combsmith.com"
     ```

   - For Node (`package.json`):

     ```json
     "funding": {
       "type": "commercial",
       "url": "https://combsmith.com"
     }
     ```

3. **Contact Address**: Route all commercial inquiries to `support@combsmith.com`.
4. **License Consistency**: Maintain the repository's open-source license file (`LICENSE`), ensuring
   standard uppercase warranty disclaimers (`WITHOUT WARRANTY OF ANY KIND`, `AS IS`) remain intact.
