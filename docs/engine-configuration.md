# Engine configuration (AI_ENGINES)

pr-review and dev-lead can run on three LLM engines: **Claude**, **Gemini** and
**Copilot**. Which engines are used, and in what order, is set with GitHub
Actions **variables** (org or repo level). Switching providers needs no code
change and no release: the next run picks the new value up.

The parsing lives in [`scripts/lib/engine-chain.sh`](../scripts/lib/engine-chain.sh).

## Variables

| Variable | Default | Meaning |
|---|---|---|
| `AI_ENGINES` | `claude,gemini,copilot` | Ordered list of **enabled** engines. An engine that is not listed is never used, not even as a fallback. The order is the fallback order, and the **first** entry is the primary engine. |
| `AI_DUCK_ENGINE` | automatic | Ordered list of engines for pr-review's rubber-duck second opinion, e.g. `gemini,claude`. Each entry is `claude`, `gemini` or `copilot`. If an engine returns no verdict, the next one runs. `none` alone turns the duck off. |
| `AI_DUCK_MODEL` | engine default | Model id for the duck. Used only on the **first** engine in `AI_DUCK_ENGINE`. |
| `AI_MODELS_CLAUDE` | see below | Claude's model list: one chain per task. |
| `AI_MODELS_GEMINI` | see below | Gemini's model list, with the same keys. |
| `AI_MODELS_COPILOT` | see below | Copilot's model list, with the same keys (one model per key). |
| `GEMINI_FLASH_MODEL` | unset | Replaces only the first model of the Gemini `triage` and `action` chains. |
| `GEMINI_PRO_MODEL` | unset | Replaces only the first model of the Gemini `deep`, `audit` and `single` chains. |
| `REVIEW_ENGINE` | unset | **Legacy** primary override for pr-review. When set, it wins over the first `AI_ENGINES` entry, as long as `AI_ENGINES` enables it. Delete it to let `AI_ENGINES` decide. |
| `DEV_LEAD_ENGINE` | unset | **Legacy** primary override for dev-lead; same rule as `REVIEW_ENGINE`. |
| `DEV_LEAD_ENGINES` | unset | **Legacy** name for `AI_ENGINES` (dev-lead, #1546). Read only when `AI_ENGINES` is unset. |

`AI_ENGINES` is comma- or space-separated and case-insensitive, for example
`claude,gemini`. Start the value with an engine name (no leading space): the
workflows read the primary from the start of the value.

## Model lists (AI_MODELS_*)

Each provider's models live in one variable, so a retired or renamed model is a
variable edit, not a code change. The parsing and the defaults are in
[`scripts/lib/engine-models.sh`](../scripts/lib/engine-models.sh).

Each entry is `<key>=<model>[,<fallback>,…]`. Separate entries with `;` or new
lines. Keys are case-insensitive and spaces around names are ignored. A key you
leave out keeps its default. A chain is walked left to right on a rate limit,
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

Defaults:

| Key | `AI_MODELS_CLAUDE` | `AI_MODELS_GEMINI` | `AI_MODELS_COPILOT` |
|---|---|---|---|
| `triage` | `claude-haiku-4-5-20251001,claude-sonnet-5-5,claude-sonnet-5` | `gemini-3.8-flash,gemini-3.1-pro-preview` | `openai/o4-mini` |
| `deep` | `claude-opus-5-5,claude-opus-4-8,claude-sonnet-5-5` | `gemini-3.1-pro-preview,gemini-3.8-flash` | `openai/o4-mini` |
| `audit` | `claude-opus-5-5,claude-opus-4-8,claude-opus-4-7` | `gemini-3.1-pro-preview,gemini-3.8-flash` | `openai/o4-mini` |
| `action` | `claude-sonnet-5-5,claude-sonnet-5,claude-opus-4-8` | `gemini-3.8-flash,gemini-3.1-pro-preview` | `openai/o4-mini` |
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
keep working:

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
`CLAUDE_<TIER>_MODEL_CHAIN` env first, then `AI_MODELS_CLAUDE`, then the built-in
default. An operator who supplies a concrete `claude-*` id still has it honoured
verbatim. In gh-aw front-matter the model family is named in `models:` (e.g.
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
| Replace a retired Gemini deep-review model | `AI_MODELS_GEMINI=deep=<new-model>,gemini-3.8-flash` |
| Pin Claude's deep review to Opus 4.8 | `AI_MODELS_CLAUDE=deep=claude-opus-4-8,claude-sonnet-5` |

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
  cross-provider fallback. Set them with `AI_MODELS_*` (above).
