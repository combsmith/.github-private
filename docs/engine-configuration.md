# Engine configuration (config/ai-engines.json, AI_ENGINES)

pr-review and dev-lead can run on three LLM engines: **Claude**, **Gemini** and
**Copilot**. Which engines are enabled, which models exist and which models each
task uses are set in one versioned file,
[`config/ai-engines.json`](../config/ai-engines.json) (#1973). A small set of
GitHub Actions **variables** stays as a documented emergency override.

The engine chain is parsed in
[`scripts/lib/engine-chain.sh`](../scripts/lib/engine-chain.sh), the model lists
in [`scripts/lib/engine-models.sh`](../scripts/lib/engine-models.sh).

## The config file

`config/ai-engines.json` is the source of truth. It has three sections:

- **`models`** — the catalog, keyed by model id. Each entry gives its
  `provider` (`claude`, `gemini` or `copilot`), its `status` (`active`,
  `preview` or `retired`) and optional `notes`, such as why a chain has its
  fallbacks, the Sonnet 5 id history and the Fable 5 deprecation.
- **`providers`** — `claude`, `gemini` and `copilot`, each with `enabled`, and
  `fallback_order`, the default order across providers (its first enabled
  entry is the primary).
- **`tasks`** — `triage`, `deep`, `audit`, `action`, `single` and `duck`. Each
  gives, per provider, an ordered chain: primary first, then fallbacks.
  `tasks.<task>.prefer` (a provider list) is accepted for per-task provider
  preference but not read yet.

The file is read with `jq`, resolved relative to `engine-models.sh` (so it is
found wherever the scripts are checked out). A missing, unreadable or malformed
file is an `::error::` and fails the step: there are no built-in defaults to fall
back to, because stale defaults are what this file replaces. `engine.sh` reads it
once when it is sourced.

**It ships like code.** The file is released with the `pr-review/*` and
`dev-lead/*` channel tags, so a default-model change canaries on `next` before
`ring0` and `stable`. An Actions variable changes every channel at once, which is
why variables are only the emergency path.

**It is checked at PR time.** The `validate-ai-engines` job in `lint.yml` runs
[`scripts/validate-ai-engines.py`](../scripts/validate-ai-engines.py). It
validates the file against
[`config/ai-engines.schema.json`](../config/ai-engines.schema.json) (JSON Schema
draft 2020-12), and also fails when:

- a task names a model that is missing from `models`, or is `retired`;
- a model sits in another provider's chain;
- a model of an enabled provider has no price row in
  [`scripts/lib/model-pricing.tsv`](../scripts/lib/model-pricing.tsv) (a
  vendor-prefixed id such as `openai/o4-mini` is priced by its bare name);
- `duck`, or any `copilot` chain, lists more than one model.

Run it locally with `python3 scripts/validate-ai-engines.py` (needs
`pip install 'jsonschema>=4'`).

## Precedence

For each task's chain, highest first:

1. **A specific environment variable** — `CLAUDE_<TIER>_MODEL_CHAIN`,
   `GEMINI_FLASH_MODEL(_CHAIN)`, `GEMINI_PRO_MODEL(_CHAIN)`, `COPILOT_API_MODEL`.
   These are **internal**: they are kept for tests and the A/B runner. Do not
   set them as Actions variables; use `AI_MODELS_*`.
2. **`AI_MODELS_*`** — the break-glass override (below).
3. **`config/ai-engines.json`**.

For providers, the file decides which are enabled. `AI_ENGINES` is the kill
switch and the fallback order: it can disable or reorder providers the file
enables, but it **cannot enable** one the file disables (that is ignored with a
`::warning::`).

## Emergency path

When a model breaks in production (retired, renamed, throttled):

1. **Now:** set the `AI_MODELS_<PROVIDER>` variable (or `AI_ENGINES` to turn a
   provider off). The next run picks it up on every channel.
2. **Then:** land the same change in `config/ai-engines.json` through a normal
   PR and release, and delete the variable once `stable` carries it.

The daily PR-review health check (`scripts/pr_review_health.sh`) lists, under
**Engine configuration overrides**, every `AI_MODELS_*` key and `AI_ENGINES`
value that is set and differs from the file, so a temporary override is folded
back instead of living on silently.

## Variables

| Variable | Default | Meaning |
|---|---|---|
| `AI_ENGINES` | the file's `providers.fallback_order` (`claude,gemini,copilot`) | Kill switch and fallback order. An engine that is not listed is never used, not even as a fallback. The order is the fallback order, and the **first** entry is the primary engine. It cannot enable an engine the file disables. |
| `AI_DUCK_ENGINE` | automatic | Ordered list of engines for pr-review's rubber-duck second opinion, e.g. `gemini,claude`. Each entry is `claude`, `gemini` or `copilot`. If an engine returns no verdict, the next one runs. `none` alone turns the duck off. |
| `AI_DUCK_MODEL` | engine default | Model id for the duck. Used only on the **first** engine in `AI_DUCK_ENGINE`. |
| `AI_MODELS_CLAUDE` | unset (the file) | **Break-glass** override of Claude's chains, one per task. |
| `AI_MODELS_GEMINI` | unset (the file) | **Break-glass** override of Gemini's chains, with the same keys. |
| `AI_MODELS_COPILOT` | unset (the file) | **Break-glass** override of Copilot's models, with the same keys (one model per key). |
| `GEMINI_FLASH_MODEL` | unset | **Deprecated** (internal). Replaces only the first model of the Gemini `triage` and `action` chains. |
| `GEMINI_PRO_MODEL` | unset | **Deprecated** (internal). Replaces only the first model of the Gemini `deep`, `audit` and `single` chains. |
| `REVIEW_ENGINE` | unset | **Legacy** primary override for pr-review. When set, it wins over the first `AI_ENGINES` entry, as long as `AI_ENGINES` enables it. Delete it to let `AI_ENGINES` decide. |
| `DEV_LEAD_ENGINE` | unset | **Legacy** primary override for dev-lead; same rule as `REVIEW_ENGINE`. |
| `DEV_LEAD_ENGINES` | unset | **Legacy** name for `AI_ENGINES` (dev-lead, #1546). Read only when `AI_ENGINES` is unset. |

`AI_ENGINES` is comma- or space-separated and case-insensitive, for example
`claude,gemini`. Start the value with an engine name (no leading space): the
workflows read the primary from the start of the value.

## Break-glass model lists (AI_MODELS_*)

Each provider has one variable that overrides its chains from the file, so a
broken model can be replaced at once, before the file change is released. The
parsing is in [`scripts/lib/engine-models.sh`](../scripts/lib/engine-models.sh).

Each entry is `<key>=<model>[,<fallback>,…]`. Separate entries with `;` or new
lines. Keys are case-insensitive and spaces around names are ignored. A key you
leave out keeps the file's chain. A chain is walked left to right on a rate limit,
before the next engine in `AI_ENGINES` is tried.

Every provider takes the same six keys, one per task:

| Key | Used for |
|---|---|
| `triage` | classify the PR |
| `deep` | agentic review |
| `audit` | security audit |
| `action` | dev-lead writer |
| `single` | single-reviewer mode |
| `duck` | the model used when this provider is the rubber duck (one model) |

`duck` takes one model on every provider. Copilot takes one model for every key,
because its GitHub Models client has no chain. A key limited to one model that is
given several warns and uses the first.

Defaults (from `config/ai-engines.json` at the time of writing — the file is
authoritative):

| Key | Claude | Gemini | Copilot |
|---|---|---|---|
| `triage` | `claude-haiku-4-5-20251001,claude-sonnet-5-5,claude-sonnet-5` | `gemini-3.8-flash,gemini-3.1-pro-preview` | `openai/o4-mini` |
| `deep` | `claude-opus-5-5,claude-opus-4-8,claude-sonnet-5-5` | `gemini-3.1-pro-preview,gemini-3.8-flash` | `openai/o4-mini` |
| `audit` | `claude-opus-5-5,claude-opus-4-8,claude-opus-4-7` | `gemini-3.1-pro-preview,gemini-3.8-flash` | `openai/o4-mini` |
| `action` | `claude-sonnet-5-5,claude-sonnet-5,claude-opus-5-5` | `gemini-3.8-flash,gemini-3.1-pro-preview` | `openai/o4-mini` |
| `single` | `claude-opus-5-5,claude-opus-4-8,claude-opus-4-7` | `gemini-3.1-pro-preview,gemini-3.8-flash` | `openai/o4-mini` |
| `duck` | `claude-sonnet-5-5` | the first `triage` model | the `triage` model |

Example, Claude with two tasks changed (the others keep their defaults):

```text
AI_MODELS_CLAUDE = deep=claude-opus-4-8,claude-sonnet-5; triage=claude-sonnet-5
```

Example, Gemini's security audit with no flash fallback (the other tasks keep
their defaults):

```text
AI_MODELS_GEMINI = audit=gemini-3.1-pro-preview
```

Example, Copilot with a stronger model for deep review and a separate duck:

```text
AI_MODELS_COPILOT = deep=openai/gpt-5; duck=openai/gpt-5-mini
```

A more specific variable still wins over `AI_MODELS_*`, so existing overrides
keep working. These are **internal / deprecated** — kept for tests and the A/B
runner (`model-ab.yml`), not for operators:

- `CLAUDE_<TIER>_MODEL_CHAIN` replaces that Claude chain.
- `GEMINI_FLASH_MODEL_CHAIN` replaces the Gemini `triage` and `action` chains.
- `GEMINI_PRO_MODEL_CHAIN` replaces the `deep`, `audit` and `single` chains.
- `GEMINI_FLASH_MODEL` / `GEMINI_PRO_MODEL` replace only the first model of
  those chains.
- `COPILOT_API_MODEL` sets the Copilot model for every key.

An unknown key, an entry without `=`, or a malformed model id is ignored, and
that tier keeps its default. Each problem is logged once per run as a
`::warning::`. The run log's `engine:` line shows the chains in use, for
example `deep: opus 5.5 [opus 4.8, sonnet 5.5]`.

## Model selection — name a family, never pin a version

The org standard (#1979, companion
[`petry-projects/.github#1199`](https://github.com/petry-projects/.github/issues/1199)):
callers name a model **family** — `opus`, `sonnet`, or `haiku` — and let the
resolver return the current concrete id. A model swap is then one edit to the
chains above, not a hunt for hard-coded ids across the tree.

`ai_model_for_family <family>` in
[`scripts/lib/engine-models.sh`](../scripts/lib/engine-models.sh) maps each family
to the tier whose primary it is and returns that tier's chain **first** model, so
the chains stay the single source of truth:

| Family | Tier |
|---|---|
| `opus` | `deep` |
| `sonnet` | `action` |
| `haiku` | `triage` |

Overrides are honoured with the same precedence engine.sh uses: the per-tier
`CLAUDE_<TIER>_MODEL_CHAIN` env first, then `AI_MODELS_CLAUDE`, then the chain
in `config/ai-engines.json`. An operator who supplies a concrete `claude-*` id
still has it honoured verbatim. In gh-aw front-matter the model family is named in `models:` (e.g.
`models: { claude: [sonnet] }`), which accepts both a family and a full id;
`engine:` selects the runner engine (`claude`), not the model. Workflow `model`
inputs likewise accept a family or a full id.

Token records keep the **resolved** id: families resolve before the engine is
called, so `TOKEN_LOG_FILE` records the concrete model, not the family name.

`scripts/check-model-pins.sh` (run in `lint.yml`) fails CI when a concrete
`claude-<family>-<version>` id appears under `.github/`, `scripts/`, `prompts/`,
`agents/`, or `personas/`. When a concrete id is genuinely required — the eval
judge held fixed for confound control, the ET baseline anchor, a last-resort
fallback — mark that line `# model-pin-ok: <reason>`; the resolver and the price
table are allow-listed.

## Common switches

| Goal | Set |
|---|---|
| Turn Copilot off | `AI_ENGINES=claude,gemini` |
| Make Gemini primary, Claude the fallback | `AI_ENGINES=gemini,claude` |
| Claude only, no cross-provider fallback | `AI_ENGINES=claude` |
| Keep the duck on Claude (same vendor, different model) | `AI_DUCK_ENGINE=claude`, `AI_DUCK_MODEL=claude-sonnet-5` |
| Duck on Gemini, then Claude if Gemini is throttled | `AI_DUCK_ENGINE=gemini,claude` |
| Duck on Gemini only, no automatic fallback | `AI_DUCK_ENGINE=gemini,none` |
| Turn the duck off | `AI_DUCK_ENGINE=none` |
| Replace a retired Gemini deep-review model (emergency) | `AI_MODELS_GEMINI=deep=<new-model>,gemini-3.8-flash`, then the same change in `config/ai-engines.json` |
| Pin Claude's deep review to Opus 4.8 (emergency) | `AI_MODELS_CLAUDE=deep=claude-opus-4-8,claude-sonnet-5`, then the same change in the file |
| Change a default model | Edit `tasks.<task>.<provider>` in `config/ai-engines.json` (add the model to `models` first) |
| Turn a provider off for good | `providers.<provider>.enabled=false` in the file |

## Behaviour

- **Unknown engine names.** A typo such as `claude,cluade` invalidates the
  whole value: the default chain is used and the run logs a `::warning::`, so a
  typo can never silently drop fallbacks.
- **Pre-flight probe.** `validate-engines.sh` checks each **enabled** engine
  before the first review. Disabled engines are reported with a notice and not
  probed. The primary is skipped when the probe finds it unusable, and a
  rate-limit fallback skips every unusable engine:
  - Gemini is usable while **any** of `GOOGLE_API_KEY`, `GOOGLE_API_KEY_2`,
    `GOOGLE_API_KEY_3` and `GOOGLE_API_KEY_4` has credits. The run warns, by key name, about any key
    that is depleted.
  - Copilot is unusable with a classic PAT (`ghp_`), which Copilot rejects.
- **Rate limits.** On a rate limit (exit 2), pr-review moves forward through
  `AI_ENGINES` from the current engine, and the switch sticks for the rest of
  the batch. If later engines are configured but none is usable, the PR is
  skipped with one notice and the batch continues. If the chain has no later
  engine at all, the session stops and retries on the next scheduled run.
- **Rubber duck.** The duck has its own fallback list. The engines in
  `AI_DUCK_ENGINE` come first, in order. Next is the built-in cross-engine
  default: Copilot when Claude is primary, Claude when Gemini is primary, and
  Gemini when Copilot is primary. Last are the other usable engines in
  `AI_ENGINES`. The primary engine is on the list only when `AI_DUCK_ENGINE`
  names it.
  - Disabled and unusable engines are left off the list. An unknown name is
    skipped with a `::warning::`.
  - An entry `none` ends the list, so `gemini,none` means Gemini or no duck.
  - If an engine returns no verdict, the next engine on the list runs. The cause
    can be a rate limit on every model and key, an auth or policy failure, or no
    JSON. The fallback works the way Gemini key rotation does, one level up.
  - A timeout ends the list, so a slow duck can't add a second timeout to the
    review.
  - The log names each engine tried. The duck's verdict line and the synthesis
    name the engine that answered. If no engine answers, the review continues
    without the duck and logs one notice.
- **Gemini key rotation.** Every Gemini call, the duck included, tries each
  configured key in turn for a model before moving to the next model. The log
  names each throttled key by its position ("API key 1 of 3"), never by its
  value.
- **Model chains inside a provider** (for example Claude's deep tier
  `claude-opus-5-5 → claude-opus-4-8 → claude-sonnet-5-5`) are walked before any
  cross-provider fallback. Set them in `config/ai-engines.json` (above), or
  with `AI_MODELS_*` in an emergency.
