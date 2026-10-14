#!/usr/bin/env python3
"""Contract test: every model-calling workflow honours the fleet pause, or is
listed as deliberately not paused (#2249).

`AGENTS_PAUSED=true` is the switch that pauses the agent fleet (#1525). Until
#2249 only dev-lead read it, so a pause stopped one agent and the rest kept
starting model calls. This test keeps the switch fleet-wide:

1. It finds every MODEL-CALLING workflow under .github/workflows by a fixed
   rule (below) and fails when one has no row in the registry,
   scripts/lib/fleet-pause-registry.tsv. A new agent cannot be added without a
   decision.
2. It checks each row against the workflow it names:
     job-gate           each listed job's `if:` starts with the pause condition
                        and the rest is a pure conjunction, so the job is
                        skipped when the variable is `true` and its condition is
                        the old one otherwise; a `fleet-paused` job runs on
                        exactly the complementary condition and logs the pause
                        source and until time. Any other model-calling job in
                        the file fails.
     job-gate-silent    the same job condition, no notice job.
     step-gate          the listed steps, and EVERY other step of that job the
                        rule flags, carry the condition; a step that runs even
                        after a failure (`always() &&`) logs the pause. Any
                        other model-calling job in the file fails.
     caller             every model-reaching job calls the named reusable in
                        this repository, and that reusable's row is a job gate.
     upstream           every model-reaching job calls the named reusable in
                        another repository. Accepted, and printed as NOT PAUSED.
     exempt             the rule flags NOTHING in the workflow. An exempt
                        workflow that gains a credential fails here.
     exempt-credential  the rule flags exactly the jobs listed, and the row says
                        why they hold a credential yet make no model call.
3. It checks every `fleet-paused` job and pause-notice step, whatever the row:
   no model credential, no AI CLI or action, no `secrets:`, no `secrets.*` or
   `github.token` reference, and every credential it would inherit from a
   workflow-level (or, for a step, job-level) `env:` blanked to ''. The notice
   runs while the fleet is paused, so it must not be able to reach a model.

The model-calling rule. A job (or, in a step-gated job, a step) reaches a model
when, outside YAML comments, it
  - names a model credential, an AI CLI or action, a model CLI invocation or a
    model API host (SIGNALS), in its own body or in the workflow-level `env:`;
  - runs a script under scripts/ whose own text holds a model CLI invocation or
    a model API host (one level: the script itself, not what it sources); or
  - calls a reusable workflow and hands it any secret (`secrets: inherit` or a
    `secrets:` mapping, whatever the names).

Known limits (also in the registry header and AGENTS.md). The rule reads
workflow YAML and, one level deep, the scripts a `run:` step invokes. It does
NOT see a model call made in a library a script sources, in a script fetched at
run time, behind a composite or third-party action, or by any means that names
none of SIGNALS. tests/test_fleet_pause_coverage.bats pins one such case.

Modes of use:
  test_fleet_pause_coverage.py [--root DIR]            check; exit 0/1
  test_fleet_pause_coverage.py [--root DIR] --table    also print, per gated job,
        whether it runs for AGENTS_PAUSED unset / false / true / TRUE
  test_fleet_pause_coverage.py [--root DIR] --markdown print the AGENTS.md
        inventory table generated from the registry

Pure offline YAML parse; returns 0/1 like the sibling contract tests.
"""
import argparse
import os
import re
import sys

import yaml

REGISTRY = "scripts/lib/fleet-pause-registry.tsv"
WORKFLOW_DIR = ".github/workflows"
THIS_REPO = "combsmith/.github-private"
GATE = "vars.AGENTS_PAUSED != 'true'"
PAUSED = "vars.AGENTS_PAUSED == 'true'"
ALWAYS_PAUSED = "always() && " + PAUSED
NOTICE_JOB = "fleet-paused"
MODES = ("job-gate", "job-gate-silent", "step-gate", "caller", "upstream",
         "exempt", "exempt-credential")
# The values a maintainer or the budget breaker can leave in the variable.
# GitHub compares strings case-insensitively, so `TRUE` pauses too.
PAUSE_VALUES = (("unset", ""), ("false", "false"), ("true", "true"), ("TRUE", "TRUE"))

# A model CLI being run, or a model API being addressed. Used on workflow text
# and on the text of scripts a `run:` step invokes.
INVOCATION = (
    r"claude\s+(?:-p\b|--print\b)|gemini\s+(?:-p\b|--prompt\b|-m\b)"
    r"|gh[ -]copilot|gh models"
    r"|api\.anthropic\.com|generativelanguage\.googleapis\.com|api\.openai\.com"
    r"|models\.github\.ai|models\.inference\.ai\.azure\.com"
)
INVOCATION_RX = re.compile(INVOCATION)
SIGNALS = (
    ("model credential", re.compile(
        r"CLAUDE_CODE_OAUTH_TOKEN|ANTHROPIC_API_KEY|GOOGLE_API_KEY|GEMINI_API_KEY"
        r"|COPILOT_GITHUB_TOKEN|OPENAI_API_KEY")),
    ("AI CLI or action", re.compile(
        r"@anthropic-ai/claude-code|@google/gemini-cli|anthropics/claude-code-action")),
    ("model CLI call or API host", INVOCATION_RX),
)
# A script under scripts/ being executed by a `run:` line: `bash x.sh`,
# `source x.sh`, `. x.sh`, or x.sh in command position. `bash -n x.sh` (a syntax
# check) and `shellcheck x.sh` are not executions.
# The path prefix is matched by alternatives that cannot start on the same
# character (an expression, a lone `$`, or any other non-separator), so the
# pattern has one way to match a given string and cannot backtrack exponentially.
SCRIPT_RUN_RX = re.compile(
    r"(?:(?<![\w./-])(?:bash|sh|source)|(?:^|[\s;&|(])\.)[ \t]+(?:-[a-mo-zA-Z]+[ \t]+)*[\"']?(?:\$\{\{[^}]*\}\}|\$(?!\{\{)|[^\s\"';|&$])*?"
    r"(scripts/[\w./-]+\.sh)"
    r"|(?:^|[;&|(])[ \t]*(?:\./)?(scripts/[\w./-]+\.sh)(?=[\s\"']|$)",
    re.M)
SECRET_REF_RX = re.compile(r"\bsecrets\s*[.\[]|\bgithub\.token\b", re.I)

MODE_LABEL = {
    "job-gate": "Job condition",
    "job-gate-silent": "Job condition, no notice",
    "step-gate": "Step condition",
    "caller": "Through its reusable",
    "upstream": "**Not paused**",
    "exempt": "Exempt",
    "exempt-credential": "Exempt, holds a credential",
}


class Failures:
    def __init__(self):
        self.items = []

    def add(self, msg):
        self.items.append(msg)
        print(f"FAIL: {msg}")


# ── expression helpers ───────────────────────────────────────────────────────

def norm_if(value):
    """An `if:` as one line: no `${{ }}` wrapper, single spaces."""
    text = "" if value is None else str(value)
    text = text.strip()
    if text.startswith("${{") and text.endswith("}}"):
        text = text[3:-2]
    return " ".join(text.split())


def has_top_level_or(expr):
    """True when `||` appears outside every parenthesis and string literal."""
    depth = 0
    in_str = False
    i = 0
    while i < len(expr):
        ch = expr[i]
        if in_str:
            if ch == "'":
                if expr[i + 1:i + 2] == "'":
                    i += 1  # '' is an escaped quote inside a literal
                else:
                    in_str = False
        elif ch == "'":
            in_str = True
        elif ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
        elif ch == "|" and expr[i + 1:i + 2] == "|" and depth == 0:
            return True
        i += 1
    return False


def split_condition(expr, head):
    """Split `<head>` or `<head> && <rest>` and return (ok, rest, why).

    `rest` must hold no top-level `||`: `&&` binds tighter than `||`, so
    `head && a || b` would run on `b` whatever `head` says.
    """
    if expr == head:
        return True, "", ""
    prefix = head + " && "
    if not expr.startswith(prefix):
        return False, "", f"must start with `{head}`"
    rest = expr[len(prefix):].strip()
    if has_top_level_or(rest):
        return False, rest, (
            f"has a top-level `||` after `{head} &&`; wrap the rest in parentheses "
            "so the pause cannot be bypassed")
    return True, rest, ""


def condition_holds(head, value):
    """Evaluate GATE or PAUSED for a variable value, the way Actions does:
    an unset variable is the empty string and string equality ignores case."""
    is_true = value.lower() == "true"
    return (not is_true) if head == GATE else is_true


# ── workflow model ───────────────────────────────────────────────────────────

def load_workflows(root):
    wf_dir = os.path.join(root, WORKFLOW_DIR)
    out = {}
    for name in sorted(os.listdir(wf_dir)):
        if not name.endswith((".yml", ".yaml")):
            continue
        with open(os.path.join(wf_dir, name), encoding="utf-8") as fh:
            doc = yaml.safe_load(fh)
        out[name] = doc if isinstance(doc, dict) else {}
    return out


def dump(node):
    return yaml.safe_dump(node, default_flow_style=False, width=100000)


def jobs_of(doc):
    jobs = doc.get("jobs")
    return jobs if isinstance(jobs, dict) else {}


def steps_of(job):
    steps = job.get("steps") if isinstance(job, dict) else None
    return [s for s in steps if isinstance(s, dict)] if isinstance(steps, list) else []


def strip_shell_comments(text):
    return "\n".join(line for line in text.splitlines() if not line.lstrip().startswith("#"))


def shell_commands(text):
    """A `run:` body without comment lines and with `\\`-continued lines joined,
    so an argument on a continuation line is not read as a command."""
    return re.sub(r"\\\n[ \t]*", " ", strip_shell_comments(text))


def without_blanked_env(node):
    """A copy of a job or step without the env entries it blanks to ''. Blanking
    an inherited credential names it; that is not holding it."""
    if not isinstance(node, dict):
        return node
    out = dict(node)
    if isinstance(out.get("env"), dict):
        out["env"] = {k: v for k, v in out["env"].items() if v not in ("", None)}
    return out


class Scanner:
    """Applies the model-calling rule. Holds the repository root so a `run:`
    step's scripts can be read, one level deep."""

    def __init__(self, root):
        self.root = root
        self._script_cache = {}

    def _script_calls_model(self, rel):
        if rel not in self._script_cache:
            path = os.path.join(self.root, rel)
            hit = False
            if os.path.isfile(path):
                with open(path, encoding="utf-8", errors="replace") as fh:
                    hit = bool(INVOCATION_RX.search(strip_shell_comments(fh.read())))
            self._script_cache[rel] = hit
        return self._script_cache[rel]

    def text_signals(self, node):
        text = dump(node)
        return [label for label, rx in SIGNALS if rx.search(text)]

    def script_signals(self, steps):
        found = []
        for step in steps:
            run = step.get("run")
            if not isinstance(run, str):
                continue
            for match in SCRIPT_RUN_RX.finditer(shell_commands(run)):
                rel = match.group(1) or match.group(2)
                if self._script_calls_model(rel):
                    found.append(f"model call in {rel}")
        return found

    def step_signals(self, step):
        return list(dict.fromkeys(self.text_signals(step) + self.script_signals([step])))

    def job_signals(self, doc, job):
        """Why a job reaches a model; empty when it does not."""
        why = self.text_signals(job)
        if reusable_target(job):
            passed = job.get("secrets")
            if passed == "inherit":
                why.append("reusable call with secrets: inherit")
            elif passed:
                why.append("reusable call with a secrets: mapping")
        else:
            why.extend(self.script_signals(steps_of(job)))
            if doc.get("env"):
                why.extend(f"{label} in workflow env" for label in self.text_signals(doc["env"]))
        return list(dict.fromkeys(why))

    def model_jobs(self, doc):
        """{job id: why it reaches a model}. The notice job is left out: it has
        its own, stricter check (check_notice_job)."""
        found = {}
        for job_id, job in jobs_of(doc).items():
            if not isinstance(job, dict) or job_id == NOTICE_JOB:
                continue
            why = self.job_signals(doc, job)
            if why:
                found[job_id] = ", ".join(why)
        return found


def reusable_target(job):
    """The `uses:` of a job that calls a reusable workflow, else None."""
    uses = job.get("uses") if isinstance(job, dict) else None
    return uses.strip() if isinstance(uses, str) else None


def flagged_env_names(env):
    """Names of the `env:` keys that would hand a job a credential.

    Only key NAMES are returned and reported; no value is ever read out of a
    workflow run here (this parses YAML text, where a value is an expression
    such as a reference into the secrets context, not the credential itself).
    """
    if not isinstance(env, dict):
        return []
    name_rx = SIGNALS[0][1]
    return [k for k, v in env.items()
            if SECRET_REF_RX.search(str(v)) or name_rx.search(str(k))]


# ── registry ─────────────────────────────────────────────────────────────────

def load_registry(root, fails):
    rows = {}
    order = []
    path = os.path.join(root, REGISTRY)
    with open(path, encoding="utf-8") as fh:
        for lineno, raw in enumerate(fh, 1):
            line = raw.rstrip("\n")
            if not line.strip() or line.startswith("#"):
                continue
            cols = line.split("\t")
            if len(cols) != 4 or any(not c.strip() for c in cols):
                fails.add(f"{REGISTRY}:{lineno}: expected 4 non-empty tab-separated columns "
                          "(workflow, mode, detail, note)")
                continue
            workflow, mode, detail, note = (c.strip() for c in cols)
            if mode not in MODES:
                fails.add(f"{REGISTRY}:{lineno}: unknown mode '{mode}' for {workflow}")
                continue
            if workflow in rows:
                fails.add(f"{REGISTRY}:{lineno}: duplicate row for {workflow}")
                continue
            if mode in ("upstream", "exempt", "exempt-credential") and note == "-":
                fails.add(f"{REGISTRY}:{lineno}: {workflow} is '{mode}' and needs a reason in the note column")
            rows[workflow] = {"mode": mode, "detail": detail, "note": note, "line": lineno}
            order.append(workflow)
    return rows, order


# ── the pause notice: it runs while paused, so it must not reach a model ─────

def check_notice_body(where, node, scanner, fails):
    """No model signal, no `secrets:`, no secret reference in a notice job or step."""
    node = without_blanked_env(node)
    if "steps" in node:   # a job
        signals = scanner.text_signals(node) + scanner.script_signals(steps_of(node))
    else:                 # a step
        signals = scanner.step_signals(node)
    for why in signals:
        fails.add(f"{where} runs while the fleet is paused and must not reach a model, "
                  f"but holds: {why}")
    if "secrets" in node:
        fails.add(f"{where} must not declare `secrets:`")
    if SECRET_REF_RX.search(dump(node)):
        fails.add(f"{where} must not reference `secrets.*` or `github.token`")


def check_env_blanked(where, own_env, inherited, fails):
    """Every credential the notice would inherit must be overridden with ''."""
    own = own_env if isinstance(own_env, dict) else {}
    for scope, env in inherited:
        for key in flagged_env_names(env):
            if key not in own or own[key] not in ("", None):
                fails.add(f"{where} inherits the credential `{key}` from the {scope} `env:`; "
                          f"blank it in the notice's own env (`{key}: ''`)")


def check_notice_text(where, steps, fails):
    text = dump(steps)
    if "::notice" not in text:
        fails.add(f"{where}: must print one `::notice` line saying the fleet is paused")
    for var in ("PAUSE_SOURCE", "PAUSE_UNTIL"):
        if var not in text:
            fails.add(f"{where}: the notice must name the pause source and until time ({var})")


def check_notice_job(name, doc, scanner, fails):
    """Runs for every workflow that has a `fleet-paused` job, whatever its row."""
    notice = jobs_of(doc).get(NOTICE_JOB)
    if not isinstance(notice, dict):
        return
    where = f"{name}: job '{NOTICE_JOB}'"
    check_notice_body(where, notice, scanner, fails)
    check_env_blanked(where, notice.get("env"), (("workflow-level", doc.get("env")),), fails)
    for step in steps_of(notice):
        if "uses" in step:
            fails.add(f"{where} must only run shell steps (found `uses: {step['uses']}`)")


# ── per-mode checks ──────────────────────────────────────────────────────────

def check_job_gate(name, doc, row, scanner, fails, table):
    jobs = jobs_of(doc)
    gated = [j.strip() for j in row["detail"].split(",") if j.strip()]
    if not gated or row["detail"] == "-":
        fails.add(f"{name}: mode {row['mode']} needs the gated job ids in the detail column")
        return
    rests = {}
    for job_id in gated:
        job = jobs.get(job_id)
        if not isinstance(job, dict):
            fails.add(f"{name}: registry names job '{job_id}', which the workflow does not have")
            continue
        ok, rest, why = split_condition(norm_if(job.get("if")), GATE)
        if not ok:
            fails.add(f"{name}: job '{job_id}' is not paused by AGENTS_PAUSED: its `if:` {why}")
            continue
        rests[job_id] = rest
        for label, value in PAUSE_VALUES:
            outcome = "runs" if condition_holds(GATE, value) else "skipped"
            table.append((name, job_id, label, outcome))
    for job_id, why in scanner.model_jobs(doc).items():
        if job_id not in gated:
            fails.add(f"{name}: job '{job_id}' reaches a model ({why}) but is not in the "
                      f"registry's gated jobs ({row['detail']})")
    notice = jobs.get(NOTICE_JOB)
    if row["mode"] == "job-gate-silent":
        if notice is not None:
            fails.add(f"{name}: mode job-gate-silent means no `{NOTICE_JOB}` job, but the "
                      "workflow has one (a paused run would finish green instead of skipped)")
        return
    if not isinstance(notice, dict):
        fails.add(f"{name}: missing the `{NOTICE_JOB}` job that logs why the run was skipped")
        return
    ok, notice_rest, why = split_condition(norm_if(notice.get("if")), PAUSED)
    if not ok:
        fails.add(f"{name}: job '{NOTICE_JOB}' `if:` {why}")
        return
    if "needs" in notice or "uses" in notice:
        fails.add(f"{name}: job '{NOTICE_JOB}' must stand alone (no `needs:`, no `uses:`), "
                  "or a skipped dependency would silence it")
    for job_id, rest in rests.items():
        if rest != notice_rest:
            fails.add(f"{name}: job '{NOTICE_JOB}' must run on the same events as '{job_id}': "
                      f"expected `{rest or '(no event filter)'}`, found `{notice_rest or '(no event filter)'}`")
    check_notice_text(f"{name}: job '{NOTICE_JOB}'", notice.get("steps") or [], fails)
    env_text = dump({"env": notice.get("env"), "steps": notice.get("steps")})
    for var in ("vars.AGENTS_PAUSE_SOURCE", "vars.AGENTS_PAUSE_UNTIL"):
        if var not in env_text:
            fails.add(f"{name}: job '{NOTICE_JOB}' must read {var}")
    for label, value in PAUSE_VALUES:
        outcome = "runs" if condition_holds(PAUSED, value) else "skipped"
        table.append((name, NOTICE_JOB, label, outcome))


def is_notice_step(step):
    cond = norm_if(step.get("if"))
    return PAUSED in cond and GATE not in cond and "::notice" in str(step.get("run", ""))


def check_step_gate(name, doc, row, scanner, fails, table):
    job_id, _, step_list = row["detail"].partition(":")
    job_id = job_id.strip()
    wanted = [s.strip() for s in step_list.split("|") if s.strip()]
    job = jobs_of(doc).get(job_id)
    if not isinstance(job, dict) or not wanted:
        fails.add(f"{name}: mode step-gate needs `<job>:<step>|<step>` naming a real job (got '{row['detail']}')")
        return
    steps = steps_of(job)
    names = [str(s.get("name", "")) for s in steps]
    for step_name in wanted:
        if step_name not in names:
            fails.add(f"{name}: registry names step '{step_name}', which job '{job_id}' does not have")
    notices = [s for s in steps if is_notice_step(s)]
    # Every step the registry names, and every other step the rule flags, must
    # carry the condition: an unlisted model-calling step is not a way round it.
    for step in steps:
        step_name = str(step.get("name", ""))
        if any(step is n for n in notices):
            continue
        why = scanner.step_signals(step)
        if step_name not in wanted and not why:
            continue
        ok, _, reason = split_condition(norm_if(step.get("if")), GATE)
        if not ok:
            cause = "" if step_name in wanted else f" (it reaches a model: {', '.join(why)})"
            fails.add(f"{name}: step '{step_name or '(unnamed)'}' is not paused by AGENTS_PAUSED{cause}: "
                      f"its `if:` {reason}")
            continue
        for label, value in PAUSE_VALUES:
            outcome = "runs" if condition_holds(GATE, value) else "skipped"
            table.append((name, f"{job_id}/{step_name}", label, outcome))
    for other_id, why in scanner.model_jobs(doc).items():
        if other_id != job_id:
            fails.add(f"{name}: job '{other_id}' reaches a model ({why}) but the registry's "
                      f"step-gate row covers job '{job_id}' only")
    if not notices:
        fails.add(f"{name}: job '{job_id}' needs a step with `if: {ALWAYS_PAUSED}` that logs the pause")
        return
    for step in notices:
        where = f"{name}: the pause notice step in job '{job_id}'"
        if norm_if(step.get("if")) != ALWAYS_PAUSED:
            fails.add(f"{where} must run even after an earlier step failed: its `if:` must be "
                      f"`{ALWAYS_PAUSED}`")
        check_notice_body(where, step, scanner, fails)
        check_env_blanked(where, step.get("env"),
                          (("workflow-level", doc.get("env")), ("job-level", job.get("env"))), fails)
        check_notice_text(where, [step], fails)
        text = dump(step)
        for var in ("vars.AGENTS_PAUSE_SOURCE", "vars.AGENTS_PAUSE_UNTIL"):
            if var not in text:
                fails.add(f"{where} must read {var}")


def check_caller(name, doc, row, rows, scanner, fails, upstream):
    target = row["detail"]
    if upstream:
        if target.startswith(THIS_REPO + "/") or "/.github/workflows/" not in target:
            fails.add(f"{name}: mode upstream needs `<owner>/<repo>/.github/workflows/<file>` "
                      f"in another repository (got '{target}')")
            return
        accepted = (target + "@",)
        local = None
    else:
        accepted = (f"{THIS_REPO}/{WORKFLOW_DIR}/{target}@",)
        local = f"./{WORKFLOW_DIR}/{target}"
        target_row = rows.get(target)
        if target_row is None or target_row["mode"] not in ("job-gate", "job-gate-silent"):
            fails.add(f"{name}: mode caller points at {target}, which has no job-gate row in the registry")

    def matches(uses):
        return bool(uses) and (uses == local or uses.startswith(accepted))

    targets = [reusable_target(job) for job in jobs_of(doc).values() if isinstance(job, dict)]
    if not any(matches(uses) for uses in targets):
        fails.add(f"{name}: no job calls the reusable the registry names ({target})")
    for job_id, why in scanner.model_jobs(doc).items():
        if not matches(reusable_target(jobs_of(doc)[job_id])):
            fails.add(f"{name}: job '{job_id}' reaches a model ({why}) outside the reusable "
                      f"the registry names ({target})")


def check_exempt(name, doc, row, scanner, fails):
    reaching = scanner.model_jobs(doc)
    if row["mode"] == "exempt":
        for job_id, why in reaching.items():
            fails.add(
                f"{name} is listed as exempt (no model call), but job '{job_id}' now matches the "
                f"model-calling rule ({why}). Gate it, or change the row to exempt-credential, "
                "name the job and say why it makes no model call.")
        return
    listed = sorted(j.strip() for j in row["detail"].split(",") if j.strip() and j.strip() != "-")
    if not listed:
        fails.add(f"{name}: mode exempt-credential needs the credential-holding job ids in the detail column")
        return
    if not reaching:
        fails.add(f"{name}: mode exempt-credential, but the model-calling rule flags nothing in "
                  "this workflow; use plain exempt")
        return
    for job_id, why in reaching.items():
        if job_id not in listed:
            fails.add(f"{name}: job '{job_id}' matches the model-calling rule ({why}) and is not "
                      f"one of the jobs the exempt-credential row accounts for ({row['detail']})")
    for job_id in listed:
        if job_id not in reaching:
            fails.add(f"{name}: the exempt-credential row names job '{job_id}', which the "
                      "model-calling rule does not flag")


# ── output ───────────────────────────────────────────────────────────────────

def cell(text):
    return text.replace("|", "\\|")


def markdown(rows, order):
    lines = ["| Workflow | How it is paused | Jobs, steps or reusable | Note |", "|---|---|---|---|"]
    for name in order:
        row = rows[name]
        detail = "" if row["detail"] == "-" else f"`{cell(row['detail'])}`"
        note = "" if row["note"] == "-" else cell(row["note"])
        lines.append(f"| `{name}` | {MODE_LABEL[row['mode']]} | {detail} | {note} |")
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--root", default=".", help="repository root (default: current directory)")
    parser.add_argument("--table", action="store_true", help="print the per-job pause truth table")
    parser.add_argument("--markdown", action="store_true", help="print the AGENTS.md inventory table")
    args = parser.parse_args()

    fails = Failures()
    rows, order = load_registry(args.root, fails)
    if args.markdown:
        print(markdown(rows, order))
        return 1 if fails.items else 0

    workflows = load_workflows(args.root)
    scanner = Scanner(args.root)
    table = []

    for name in order:
        if name not in workflows:
            fails.add(f"{REGISTRY}:{rows[name]['line']}: {name} is not a file under {WORKFLOW_DIR}")

    not_paused = []
    for name, doc in workflows.items():
        check_notice_job(name, doc, scanner, fails)
        row = rows.get(name)
        if row is None:
            reaching = scanner.model_jobs(doc)
            if reaching:
                detail = "; ".join(f"job '{j}': {why}" for j, why in reaching.items())
                fails.add(
                    f"{name} can reach a model ({detail}) but has no row in {REGISTRY}. Gate its "
                    f"model-calling job on `{GATE}` and add a job-gate row, or add an exempt row "
                    "with the reason (see AGENTS.md, \"Pausing the agent fleet\").")
            continue
        mode = row["mode"]
        if mode in ("job-gate", "job-gate-silent"):
            check_job_gate(name, doc, row, scanner, fails, table)
        elif mode == "step-gate":
            check_step_gate(name, doc, row, scanner, fails, table)
        elif mode == "caller":
            check_caller(name, doc, row, rows, scanner, fails, upstream=False)
        elif mode == "upstream":
            check_caller(name, doc, row, rows, scanner, fails, upstream=True)
            not_paused.append(f"{name} (model call in {row['detail']})")
        else:
            check_exempt(name, doc, row, scanner, fails)

    if args.table:
        for entry in table:
            print("\t".join(entry))
    for item in not_paused:
        print(f"NOT PAUSED: {item}")
    if fails.items:
        return 1
    counts = {}
    for name in order:
        counts[rows[name]["mode"]] = counts.get(rows[name]["mode"], 0) + 1
    summary = ", ".join(f"{counts[m]} {m}" for m in MODES if m in counts)
    print(f"PASS: every model-calling workflow honours AGENTS_PAUSED or is listed ({summary})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
