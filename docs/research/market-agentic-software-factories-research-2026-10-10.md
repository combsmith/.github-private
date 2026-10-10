# Market Research: agentic software factories

**Status:** Complete — for maintainer review
**Date:** 2026-10-10
**Research type:** Market
**Method:** BMAD market-research workflow (`bmad-market-research`), run by the analyst persona
**Priority segment:** solo founders and indie builders
**Inputs:** [architecture review](../architecture/factory-mvp-architecture-review.md) §13, §15, §16;
[PRD](../prd/agentic-software-factory.md)

## Executive summary

1. **"Software factory" became the category label in 2026, and almost every product that uses it
   keeps a human at the merge.** Four vendors refuse in writing to merge to a default branch. The
   no-human-review "dark factory" is one company's published practice.
2. **Writing code is now a commodity; verifying it is the bottleneck.** Issue-to-pull-request,
   CI repair and first-pass review are each offered by eight or more products, several free on
   public repos. The largest telemetry study found review time up fivefold and incidents per pull
   request up threefold as agent output grew.
3. **The price of automation is moving from flat to metered.** Interactive use stays at $20 to
   $200 a month. Unattended and CI use is being moved to API rates: GitHub did it on 1 June 2026;
   Anthropic announced the same for its programmatic use and paused it on the day. A solo factory's
   economics depend on which side of that line its workload falls.
4. **Model providers are absorbing the layer above them.** First-party agents overtook the
   independent tool vendors within six months, providers are buying the toolchain, and more than a
   dozen products in this space were shut, sold or renamed in a year.
5. **The solo builder's pains are the ones this org measured in itself:** review burden, usage caps
   and unpredictable cost, work that passes tests and is wrong, and the attention it takes to
   supervise. One person runs two to five agents, with a ceiling near eight.
6. **Attention at the orchestration layer is large and does not convert to revenue.** A dozen open
   projects hold between 6,000 and 100,000 stars. The best-known commercial one, with thousands of
   daily users, closed for want of a business model, and the best-known open one was disowned by
   its author.
7. **Five things no product offers a solo builder today:** a governed, unattended merge on the
   operator's own policy; release and operation at solo price; a cross-repo view of why each work
   item is waiting; one versioned definition rolled out in stages across a portfolio; and admission
   of work against a flat subscription with reviewers independent of the writer's vendor.
8. **The main barrier is unproven value.** Nothing shows that a factory beats one well-run agent
   for a single person with a modest backlog. The burden of proof is on the factory.
9. **The nearest substitute is GitHub's own.** Agentic Workflows already ships the pattern in which
   the agent requests effects and a separate job applies them, with spend ceilings, under an open
   licence. On GitHub's documentation an agent-approved merge is one setting and one preview away.

**What this means for the PRD** is in §7. In short: build the control plane and the merge decision,
adopt the workers and the reviewers, plan for metered capacity, and prove the factory against a
single-agent baseline before claiming it is better.

## 1. Introduction and method

### 1.1 Why this research now

The architecture review treated this org's factory as a proof of concept and proposed a production
MVP. It compared seven systems on their design. It did not ask what the market offers a buyer, who
that buyer is, or what vendors will ship before the MVP is finished. This research does.

### 1.2 Scope

- **Topic:** products, platforms and open projects that promise to take software from intent to a
  shipped, maintained change with agents doing most of the work.
- **Customer:** solo founders and indie builders: one person, one or many products, consumer or pro
  subscriptions, no operations team and no second reviewer.
- **Geography:** global; English-language sources.

### 1.3 Method and limits

- Three parallel research passes on 2026-10-10: market definition, size and pricing; the customer;
  and a competitive teardown from a solo builder's seat.
- Claims are marked **(P)** where the company's or author's own page was read, **(S)** where the
  source is press or a third party, and listed in §8 where they could not be established.
- Vendor numbers are vendor claims. Every merge-rate and productivity figure found for a coding
  agent is self-reported; no independent quality evidence for any agent's merged output was found.
- Pages were read through a fetcher that returns a model-extracted rendering. Figures should be
  re-opened before being quoted elsewhere.
- Reddit could not be read. First-hand customer evidence leans on Hacker News, which skews technical
  and sceptical.
- No survey isolates solo builders. Segment findings combine general developer surveys with
  first-hand accounts.

## 2. Market analysis and dynamics

### 2.1 Definition and categories

There is no settled name. Gartner renamed its coverage "Enterprise AI Coding Agents" in May 2026
(S). Forrester uses "Agentic Development Platforms" (S). Practitioners say "software factory",
"dark factory" and "harness engineering". The categories below describe jobs, not companies; every
vendor in the first two now ships pieces of the others.

| Category | What it does | Buyer | Examples |
|---|---|---|---|
| Assistants and AI-native editors | Completion, chat, an in-editor agent; a human per change | Developer; seat buyer | GitHub Copilot, Cursor, Devin Desktop, Kiro |
| Autonomous coding agents | Take a task, plan, edit, test, open a pull request, locally or in a cloud sandbox | Developer; engineering lead | Claude Code, Codex, Devin, Jules, Factory Droids |
| Orchestration and "software factory" platforms | Run many agents through intake, specification, build, verification and shipping | Head of engineering; small teams | Factory, 8090, Warp Factories, Harness Cosmos, Gas Town, Symphony |
| Prompt-to-app builders | A prompt to one hosted, deployed app | Non-developers, founders | Lovable, Replit, Bolt, v0 |
| Review and verification | Automated review, bug finding, fix loops | Engineering manager; maintainer | CodeRabbit, Greptile, Cursor Bugbot, Gitar, cubic |
| Agentic CI and control planes | Agents inside the forge with identity, permissions, budgets, audit | Platform and security | GitHub Agent HQ and Agentic Workflows, Claude Managed Agents, Codex cloud |
| Spec-driven development | The written spec is the durable artefact | Tech leads | Spec Kit, Kiro, Tessl, OpenSpec, BMAD |
| Internal factories | In-house systems cited as proof | Not for sale | StrongDM, Stripe, Ramp, OpenAI's internal harness |

**Who says "software factory".** It is a product name at 8090 and Warp, and positioning at Factory,
Augment (now Harness), Tessl and others. All of those keep human gates at specification and at
merge. Only StrongDM publishes a practice with no human review (P).

### 2.2 Size and growth

Published estimates disagree by a factor of three or more, and none was opened directly (all S).

| Horizon | Range | What explains the spread |
|---|---|---|
| 2025 | $4.0B to $11.8B | Enterprise application spend only, against anything "AI for developers" |
| 2026 | $9.4B to $16.1B | Scope and base year |
| 2030–2031 | $25.7B to $97.9B | Compound growth of 25% to 48% assumed |

The forecasts look stale against stated revenue. Run-rates reported for a handful of leaders already
sum past $8B a year before GitHub Copilot and Codex, neither of which discloses revenue.

| Company | Reported traction | Kind |
|---|---|---|
| Cursor | About $4B annualised, June 2026; reported acquired by SpaceX in an all-stock deal | Press, single source for the revenue figure |
| Claude Code | Above $2.5B run-rate, February 2026 | Press |
| Cognition (Devin) | Above $1B run-rate, September 2026; includes the former Windsurf line | Company |
| GitHub Copilot | 50M users including free tiers, July 2026; 4.7M paid, January 2026 | Company |
| Lovable | About $500M annual run-rate, June 2026 | Company |
| Factory | Raised at a $5B valuation, September 2026; revenue not disclosed | Company and press |
| 8090 | Raised $135M, June 2026; revenue not disclosed | Company |

**No estimate sizes the orchestration or "software factory" category by itself.**

### 2.3 Adoption

- **Agents are the default at work.** 90% of professional developers use coding agents at least
  weekly and 68% daily (JetBrains, more than 15,000 developers, mid-2026, P).
- **First-party agents overtook the tool vendors in six months.** Share using each at work, January
  to mid-2026: Claude Code 18% to 39%, Codex 3% to 16%, Cursor 18% to 12%, Copilot 29% to 21%
  (JetBrains, P).
- **A fifth to a quarter of merged work is agent-authored.** 19.4% of public pull requests in August
  2026 carried an agent mark (Amplifying, P). One review vendor's data put fully AI-authored merged
  pull requests at 27.6% in April 2026 (Greptile, vendor, P).
- **Much of it merges unreviewed.** In a sample of 268 merged agent pull requests in significant
  repos, 56% had no human reviewer (Amplifying, P).
- **Trust is conditional.** 48% of developers trust AI output only when they can easily verify it
  (Stack Overflow 2026, 30,903 responses, P).
- **Output is up; delivery is not.** Across about 22,000 developers, high-adoption periods showed
  task throughput up 34%, bugs per developer up 54%, incidents per pull request up 243%, median
  review time five times longer, and deployments per week down 11.7% (Faros, an analytics vendor;
  correlational, P). The one randomised programme says it can no longer measure the effect cleanly
  (METR, February 2026, P).

### 2.4 Trends since early 2026

1. **Long, unattended runs.** Vendors describe agents working for hours or days. First-hand accounts
   of overnight runs from ordinary solo builders are scarce.
2. **Verification is the binding constraint.** One vendor uses those words (Augment, P); the
   telemetry above agrees; code review is the most acquired adjacent category.
3. **Seats became metered usage.** GitHub moved Copilot to token-metered credits on 1 June 2026,
   saying flat pricing was "no longer sustainable" (P). Cursor's review product moved from a seat
   price to a per-run price (S).
4. **Providers are absorbing the stack.** They ship their own control planes (Claude Managed Agents,
   Codex cloud, GitHub Agent HQ hosting third-party agents) and are buying runtimes, package managers
   and cloud development environments (S).
5. **Agents on CI.** GitHub Agentic Workflows went from technical preview in February to public
   preview in June 2026 (P, S).
6. **Agents with write credentials in CI are the attack surface.** Three disclosed incidents in 2026
   share one root cause: an agent holding a write token read untrusted repository text as
   instructions (Cloud Security Alliance research note, S).
7. **Churn.** Shut, sunset, sold or renamed within about a year: Charlie Labs, Vibe Kanban's company,
   Crystal, Firebase Studio, Amazon Q Developer, Windsurf, Gemini CLI for subscribers, Graphite,
   Gitar, Cursor, and Augment's Cosmos, sold to Harness two days before this report (P and S).

### 2.5 Pricing and business models

| Model | Who | What it means for an unattended factory |
|---|---|---|
| Flat subscription with rolling limits | Claude, Codex, Factory | Cheapest by far while it lasts. Limits are unpublished and changeable |
| Subscription that is a prepaid balance at API rates | Copilot, Amp, v0, Replit | Predictable only up to the balance |
| Per review or per run | Claude Code Review at about $15–25, Bugbot at about $1–1.50, Greptile overage | Scales with pushes |
| Bring your own key or plan | Most open projects; Tembo, Amp, Warp, Devin increasingly | The operator carries the model bill |
| Outcome-based | One product, per merged change | Rare |

**The line that matters.** An individual working interactively stays inside $100 to $200 a month on
one flat plan. Anyone running agents unattended, in CI or in parallel is being moved onto metered
credits or API keys, where credible figures run from the low thousands a month upward.

**The specific risk to this org.** Anthropic announced in May 2026 that programmatic use of Claude
Code (`claude -p`, the Agent SDK, GitHub Actions) would move off subscription limits onto a small
monthly credit and then API rates, and paused the change on its 15 June start date. No new date has
been given. Its guidance for automation shared across repos is an API key. Its monthly API credits
exclude runs started by its GitHub Action (S for the announcement and pause; P for the pricing page,
which says Claude Code "shares the same usage limits as the rest of your plan"). Google withdrew its
CLI from individual subscribers on about thirty days' notice (P). GitHub's charge for self-hosted
runner minutes is postponed, not withdrawn; public-repo minutes "will remain free" (P).

## 3. Customer insights: the solo builder

### 3.1 Segments and behaviour

| Segment | Defined by | Fit for a GitHub-native factory |
|---|---|---|
| A. Non-technical founders on prompt-to-app builders | Cannot read the code; ship from a chat box | **None.** The largest group by head-count and excluded by construction |
| B. Technical indie hackers on terminal and editor agents | Review code, own the repo and the deployment | **Best.** The natural early adopter and the best-evidenced segment |
| C. Solo open-source maintainers | Receive agent output as well as produce it | Partial: their pain is inbound |
| D. One-person agencies | Sell delivery | Thin evidence |
| E. Portfolio builders | One person, many small products; attention is the limit | **Good**, and closest to this org. Thin evidence: a handful of loud accounts |

How segments B and E work today:

- **Two to five agents at once, with a ceiling near eight.** The limit people name is their own
  attention, not tooling (several first-hand accounts, P).
- **The human moved up, not out.** Planning and acceptance are where the person now sits. One
  developer puts about 80% of their time into thinking (P).
- **A second model as reviewer is common practice.** One builder runs a push hook that needs two
  frontier models to approve and fails closed (P).
- **Spend sits in three bands:** up to $20 a month for most; $100 to $200 for serious builders; a
  small tail spending far more through stacked subscriptions.
- **Workflows have a short shelf life.** Builders report abandoning whole setups when a model
  release changes what works, and dropping their own orchestration when the agent gains sub-agents.

### 3.2 Pain points, ranked

| # | Pain | Evidence | What people do today |
|---|---|---|---|
| 1 | Review burden and low-quality output | Strong: two surveys, telemetry, several widely read essays | A second model, plan first, thin slices; or stop reading code |
| 2 | Usage caps, unpredictable cost, plan changes | Strong: about 30% hit limits; repeated large threads | Ration, switch tool, stack accounts, turn off overage |
| 3 | The gap from prototype to production | Strong for segment A: a paid rescue trade exists | Hire help, rewrite, give up |
| 4 | Passes tests and is wrong; tests edited or results misreported | Moderate: many concrete reports, no survey | Protect tests, check outside the model |
| 5 | Supervising many agents | Moderate to strong: consistent accounts, vendor telemetry | Cap at two to five, notifications |
| 6 | Leaked secrets, destructive actions, guardrails that are only advice | Strong on incidence, weaker as a felt pain | Sandboxes, scoped tokens; often nothing |
| 7 | Context lost across sessions | Moderate | Instruction files, task memory, fresh sessions |
| 8 | Lock-in and sudden policy change | Moderate and spiky | Use two to four tools at once |

This org's own telemetry shows pains 1, 2, 4 and 5 at fleet scale (architecture review §2, §14).

### 3.3 Unmet needs

1. **A stopping rule they can trust when nobody is watching:** "done" checked by something the agent
   cannot argue with. Strong evidence.
2. **A hard cap on spend.** People switch overage off after one surprise. Nobody was found asking for
   cost per shipped change in those words; the need is implied.
3. **Review that scales past one person without becoming no review.**
4. **Guardrails without a platform team.** Solo builders assemble them from containers and scoped
   tokens. Strong evidence that the need exists; no product named as meeting it.
5. **A record of what the agents did and why something is stuck.** Moderate; mostly inferred.
6. **Operating a portfolio of repos.** Thin evidence.

### 3.4 How they decide, and what they pay

- **Tools are added, not swapped.** 70% use two to four (Pragmatic Engineer, 906 responses, P).
- **Quality moves people about four times as often as price.** 25.1% switched for better output,
  6.4% for lower cost (Stack Overflow 2026, P). Caps and policy shocks are the acute triggers.
- **Decision criteria, by weight:** output quality (very high); usage headroom per dollar (high);
  works with the subscription and agent they already have (high for this layer); control and
  visibility (high among technical builders); low setup cost (high); open and self-hostable (medium
  to high); price (medium, with a hard floor near $20); autonomy (medium and polarising).
- **Willingness to pay for the model:** $20 by default; $100 to $200 while it buys far more than its
  API-rate value.
- **Willingness to pay for orchestration on top: low.** Vibe Kanban had thousands of daily users,
  most on the free tier, and its company closed saying it could not find a business model (P).
  Prices that exist at this layer are free or about $20 a seat.
- **Most indie products earn little.** Two analyses put median revenue near $150 a month (S), which
  caps what the median builder can justify.

### 3.5 Barriers to a factory, as opposed to one agent

| Barrier | Strength |
|---|---|
| **No proof it beats one good agent.** Research shows multi-agent setups hurting sequential work; practitioners report two or three focused agents beating six to eight; the author of the best-known orchestrator abandoned reusable orchestration | **Strong: the main barrier** |
| The platform absorbs the feature | Strong |
| Cost multiplication and fear of runaway spend | Strong |
| Trust | Strong |
| Setup complexity | Moderate to strong |
| Too little designed work to feed it: design is the bottleneck once code is cheap | Moderate |
| Fear of breaching subscription terms | Moderate |

### 3.6 Signals for and against

**For.** About a dozen open projects created in eighteen months hold 6,000 to 100,000 stars each,
including a self-hosted control plane with budgets and approvals at about 100,000. The official
action for running Claude Code on GitHub's CI has about 9,500. Vendors are shipping scheduled agents
natively, which confirms the need.

**Against.** Attention has not converted to revenue. The most-read essays of 2026 argue for less
autonomy. One detailed account of a solo, self-hosted factory moved off GitHub for isolation, CI
limits and outages. Nothing shows solo builders want this *GitHub-native* in particular.

## 4. Competitive landscape

### 4.1 How much of the loop each automates

*auto*: runs on an event or schedule with no per-item human action. *trig*: the agent does the step
once a person, label or mention starts it. *human*: a person does or must approve it. A dash: not
offered. A question mark: not established.

| Product | Intake | Plan | Build | CI repair | Review | Merge decision | Release | Operate |
|---|---|---|---|---|---|---|---|---|
| GitHub Copilot stack | trig | trig | trig | trig | auto | trig, preview | — | — |
| GitHub Agentic Workflows | auto | trig | trig | trig | trig | refused | trig | ? |
| Claude Code cloud and routines | auto on schedule | trig | trig | auto | auto | human | trig | trig |
| OpenAI Codex | trig | human | trig | trig | auto | — | — | — |
| Cursor | trig | auto, beta | trig | auto | auto | human | monitor only | trig |
| Cognition Devin | trig | auto | trig | auto | auto | human | — | trig |
| AWS Kiro | trig | auto | trig | auto | human | refused | — | — |
| Factory | trig | human | trig | trig | auto | ? | human, preview | trig |
| Warp Factories | trig | human | trig | trig | auto | refused | — | trig |
| Harness Cosmos | trig | ? | trig | auto | auto | human | ? | trig |
| Gitar | — | — | — | auto | auto | auto, opt-in | — | — |
| Gas Town | human | trig | auto | ? | ? | auto on gates | — | — |
| *This org's factory, as designed* | *auto* | *auto* | *auto* | *auto* | *auto, council* | *policy; human approves outcomes* | *staged, of the factory itself* | *not in the MVP* |

Reading it:

- **Build, CI repair and review are commodity.** Eight or more products do each.
- **The merge decision is the step every vendor hands back.** Kiro "never merges changes
  automatically"; Warp: "The factory never merges"; Cosmos: a human "always owns and performs the
  final merge"; Agentic Workflows refuses merges to the default branch (all P).
- **The pieces of an agent-approved merge exist on GitHub, switched off.** Copilot code review can
  submit an approval that counts toward required reviews, in preview since 1 September 2026 and off
  by default (P). Several review vendors document an opt-in auto-approve.
- **Release and operate are empty at solo price.** What exists is preview or enterprise.

### 4.2 Positioning

Two axes separate the field: how much of the loop runs unattended, and how much control the operator
keeps (declared state, the agent's own identity, a reviewer that is not the writer, loop and cost
bounds, audit, configuration in the operator's own Git and CI).

- **High automation, high control: thinly occupied.** Warp Factories, Harness Cosmos and Factory's
  preview come nearest. All stop at merge and are early-access, enterprise or contact-gated.
- **Moderate automation, high control: the toolkit band.** GitHub Agentic Workflows has the strongest
  published control model: a read-only agent job, separate jobs that apply its requested effects, a
  threat-detection job, and credit ceilings per run. It is open-licensed, a public preview, and a
  toolkit the operator must assemble per repo.
- **High automation, lower control: trust the vendor.** Cursor has the widest coverage. Devin and the
  Copilot stack follow. The same vendor writes, reviews and can approve.
- **Narrow, moving up: the verification layer.** Gitar, cubic and CodeRabbit own three columns and
  are extending toward fix-and-merge.
- **Different game.** Prompt-to-app builders automate an idea into one hosted app. None takes
  issues, reviews code or manages releases across existing repos.

### 4.3 What is commodity, and what nobody offers

**Several now offer it; building it is redundant:**

- Issue-to-pull-request implementation in a sandbox.
- CI repair and review follow-up on the agent's own pull request.
- Automatic first-pass review, free on public repos.
- Event and schedule triggers.
- A separate agent identity.
- Requested effects with a separate applier (Agentic Workflows).

**Nobody offers a solo builder:**

1. A governed, unattended merge decision on the operator's own policy, with an approver that is not
   the writer.
2. Release and operation at solo price.
3. A view across a portfolio of why each work item is waiting.
4. One versioned definition rolled out in stages across about a dozen public repos.
5. Admission of work against a flat subscription's remaining capacity.
6. Verification by reviewers from different vendors plus deterministic tools.
7. Holdout verification as software. StrongDM's version ships as three specification files.

### 4.4 Threats and openings

#### Threats to a small, open, GitHub-native factory

- **GitHub absorbs the control plane.** Triage controls, automations, review with approval, an agent
  merge and Agentic Workflows together cover intake through merge. Its automations are not available
  on public repos today, with support described as coming.
- **Subscription terms.** §2.5. This is the largest single risk to the economics.
- **Free review tiers** remove a reason to build reviewers.
- **Churn.** Anything the factory integrates may not exist next quarter.
- **The name is taken.** Companies with hundreds of millions in funding sell "software factory".

#### Openings: what vendors structurally will not do

- **Take the merge decision on the operator's policy.** A vendor that merges owns the blame. An
  operator can accept that risk for their own repos.
- **Verify with competitors' models.** A council mixing deterministic tools, tests and reviewers from
  different vendors is against each model vendor's interest.
- **Minimise the operator's spend.** Vendors earn from metered usage. This opening is narrowing as
  more products accept the user's own plan.
- **Serve one person on public repos with full governance.** Audit, service accounts and managed
  review sit on team and enterprise tiers.
- **Keep everything in the operator's Git and CI,** with nothing always on.
- **Roll the automation itself out in stages across a portfolio.** Not documented by anyone.

## 5. Strategic implications

1. **The differentiated part is small, and it is the right part.** The market has commoditised the
   workers and first-pass review. What it does not offer is the control plane around them: the merge
   decision, the council, portfolio rollout, budget admission. That is the part ADR-0012 proposes to
   build. The research supports the choice and narrows it.
2. **Adopt what is commodity.** Building a worker harness is competing with ten vendors and with an
   open-licensed toolkit from the platform owner. The run contract should be shaped so that toolkit,
   or a vendor's agent, can fill it.
3. **The council is the strongest opening and the least crowded.** No product documents reviewers
   drawn from independent vendors plus deterministic tools.
4. **Plan the economics for metered capacity.** A design that works only while subscription
   automation is tolerated has a single point of failure outside the operator's control.
5. **The customer is the technical solo builder and the portfolio builder.** The largest solo
   segment cannot use this and should be named as out of scope.
6. **Prove it against one agent.** The strongest objection in the market is that orchestration does
   not beat a single well-run agent. The factory's own Ledger can answer that and should be made to.
7. **Do not plan on selling the orchestration layer.** Attention is large; willingness to pay is low;
   the platform owner is closing in; and one vendor's terms bar third parties from offering its
   subscription login in their products. The evidence supports a factory built for this org, open
   for others to read.

## 6. Risks

| Risk | Likelihood | Effect | Mitigation |
|---|---|---|---|
| Subscription automation is restricted or repriced | High: announced once, paused, not cancelled | Capacity cost rises several-fold | Engine independence; a costed metered fallback; hard spend caps |
| GitHub ships a governed agent merge and public-repo automations | High within a year | The control plane's distinct surface shrinks | Build on its primitives; keep the Kernel separable; adopt its toolkit where it fits |
| A factory does not beat one agent for one person | Unknown | The premise fails | Measure against a single-agent baseline before widening scope |
| An integrated product disappears | High | Rework | Contracts, not integrations; the registry of §16 of the review |
| An agent holding a write credential reads hostile text | Demonstrated three times in 2026 | Secret theft, poisoned releases | The run contract's credential boundary |

## 7. Implications for the PRD

Applied to the PRD in this revision:

1. **§2 Why now:** the industry telemetry that matches this org's own.
2. **§1 Vision:** what the market does not offer, as the statement of what is distinctive.
3. **§3 Users:** the technical solo builder and portfolio builder as the user; non-technical founders
   as a named non-user.
4. **§5 Constraints:** capacity terms can change on short notice (new C-11); C-3 records the paused
   change to programmatic use.
5. **§6:** a requirement that the Factory can run on metered capacity under a hard cap; a requirement
   to adopt commodity workers and reviewers through the contract.
6. **§9 Success metrics:** a comparison against a single-agent baseline.
7. **§10 Scope:** a build-versus-adopt table.
8. **§11 Open questions:** whether to adopt GitHub Agentic Workflows as the worker half; the metered
   fallback budget.

Left for the maintainer, and not changed:

- **The non-goal "not a product for other organisations".** The evidence supports keeping it (§5,
  item 7). It could be restated as "not a commercial product; open for others to read and reuse".
- **Release and operation.** The widest gap in the market and outside the MVP. Whether it becomes
  the next scope after exit is a strategy decision.

## 8. What could not be established

- A size for the orchestration or "software factory" category.
- The number of solo builders running coding agents, or its growth.
- Any survey data specific to solo builders; anything first-hand from Reddit.
- The price at which a solo builder leaves an orchestration product.
- Demand for GitHub-native operation specifically, or for cost per shipped change as a metric.
- Whether unattended overnight runs work for ordinary builders.
- Independent quality evidence for any agent's merged output.
- Real monthly spend for a solo operator on any commercial product.
- Numeric limits on the flat plans of Anthropic, OpenAI, Cognition, Cursor and Google.
- Whether a third-party bot's approval satisfies GitHub's required-review rule.
- Revenue for Codex, Copilot, Factory and 8090; several vendors' pricing pages.
- The 2026 editions of DORA and Octoverse, which appear unpublished.

## 9. Sources

Market and adoption

- JetBrains, AI coding agent adoption 2026: <https://blog.jetbrains.com/research/2026/08/ai-coding-agent-adoption-2026/>
- Stack Overflow Developer Survey 2026: <https://survey.stackoverflow.co/2026/ai>
- Faros AI, "The Acceleration Whiplash": <https://faros.ai/research/ai-acceleration-whiplash>
- Amplifying, State of the Coding Agent Market: <https://edge.amplifying.ai/research/state-of-coding-agents>
- Greptile, "Rise of the overnight agents": <https://greptile.com/blog/rise-of-the-overnight-agents>
- METR, uplift update: <https://metr.org/blog/2026-02-24-uplift-update/>
- Pragmatic Engineer, AI tooling 2026: <https://newsletter.pragmaticengineer.com/p/ai-tooling-2026>
- StrongDM Software Factory: <https://factory.strongdm.ai/>
- Augment, "What is a software factory": <https://www.augmentcode.com/guides/what-is-a-software-factory>
- TechCrunch on Warp Factories: <https://techcrunch.com/2026/08/18/warps-new-system-is-an-out-of-the-box-software-factory-for-ai-development/>
- Cloud Security Alliance research note on coding-agent incidents: <https://labs.cloudsecurityalliance.org/research/csa-research-note-claude-code-github-action-prompt-injection/>

Pricing and terms

- GitHub, Copilot usage-based billing: <https://github.blog/news-insights/company-news/github-copilot-is-moving-to-usage-based-billing/>
- Claude pricing: <https://claude.com/pricing>
- Anthropic, using the Agent SDK with a Claude plan: <https://support.claude.com/en/articles/15036540-use-the-claude-agent-sdk-with-your-claude-plan>
- Hacker News, "We're pausing the Agent SDK credit change (Anthropic)": <https://news.ycombinator.com/item?id=48545980>
- Google, transitioning Gemini CLI: <https://developers.googleblog.com/an-important-update-transitioning-gemini-cli-to-antigravity-cli/>
- GitHub Actions runner pricing: <https://docs.github.com/en/billing/reference/actions-runner-pricing>

Competitors

- GitHub, Copilot code review can approve pull requests: <https://github.blog/changelog/2026-09-01-copilot-code-review-can-now-approve-pull-requests>
- GitHub, about Copilot automations: <https://docs.github.com/en/copilot/concepts/agents/cloud-agent/about-automations>
- GitHub Agentic Workflows: <https://github.github.com/gh-aw/introduction/overview/>, <https://github.github.com/gh-aw/reference/safe-outputs/>
- Claude Code routines and projects: <https://code.claude.com/docs/en/routines>, <https://code.claude.com/docs/en/claude-projects>
- Kiro autonomous agent: <https://kiro.dev/docs/autonomous-agent/>
- Factory: <https://docs.factory.com/>, <https://factory.com/news/series-c>
- Gitar: <https://www.sonarsource.com/products/gitar/>

Customer

- Vibe Kanban shutdown: <https://vibekanban.com/blog/shutdown>
- Steve Yegge, "The shape of things to come": <https://yegge.ai/essays/the-shape-of-things-to-come/>
- Maggie Appleton on Gas Town: <https://maggieappleton.com/gastown>
- Manuel Schipper, parallel coding agents: <https://schipper.ai/posts/parallel-coding-agents/>
- Jake Saunders, a self-hosted factory: <https://blog.jakesaunders.dev/building-an-almost-fully-self-hosted-sandboxed-agentic-software-factory/>
- Google Research, scaling agent systems: <https://research.google/blog/towards-a-science-of-scaling-agent-systems-when-and-why-agent-systems-work/>
- Open projects' star counts: repository pages, read 2026-10-10.
