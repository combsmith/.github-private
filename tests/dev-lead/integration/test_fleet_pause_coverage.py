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
     job-gate         each listed job's `if:` starts with the pause condition
                      and the rest is a pure conjunction, so the job is skipped
                      when the variable is `true` and its condition is the old
                      one otherwise; a `fleet-paused` job runs on exactly the
                      complementary condition and logs the pause source and
                      until time. Any other model-calling job in the file fails.
     job-gate-silent  the same job condition, no notice job.
     step-gate        the listed steps carry the condition and a step in the
                      same job logs the pause.
     caller           every model-reaching job calls the named reusable in this
                      repository, and that reusable's row is a job gate.
     upstream         every model-reaching job calls the named reusable in
                      another repository. Accepted, and printed as NOT PAUSED.
     exempt           a reason is recorded.

The model-calling rule. A job reaches a model when, outside YAML comments, it
  - names a model credential or an AI CLI / action (SIGNALS), in its own body
    or in the workflow-level `env:`; or
  - calls a reusable workflow with `secrets: inherit`.

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
THIS_REPO = "petry-projects/.github-private"
GATE = "vars.AGENTS_PAUSED != 'true'"
PAUSED = "vars.AGENTS_PAUSED == 'true'"
NOTICE_JOB = "fleet-paused"
MODES = ("job-gate", "job-gate-silent", "step-gate", "caller", "upstream", "exempt")
# The values a maintainer or the budget breaker can leave in the variable.
# GitHub compares strings case-insensitively, so `TRUE` pauses too.
PAUSE_VALUES = (("unset", ""), ("false", "false"), ("true", "true"), ("TRUE", "TRUE"))

SIGNALS = (
    ("model credential", re.compile(
        r"CLAUDE_CODE_OAUTH_TOKEN|ANTHROPIC_API_KEY|GOOGLE_API_KEY|GEMINI_API_KEY"
        r"|COPILOT_GITHUB_TOKEN|OPENAI_API_KEY")),
    ("AI CLI or action", re.compile(
        r"@anthropic-ai/claude-code|@google/gemini-cli|anthropics/claude-code-action"
        r"|gh[ -]copilot|gh models")),
)

MODE_LABEL = {
    "job-gate": "Job condition",
    "job-gate-silent": "Job condition, no notice",
    "step-gate": "Step condition",
    "caller": "Through its reusable",
    "upstream": "**Not paused**",
    "exempt": "Exempt",
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


def signals_in(node):
    text = dump(node)
    return [label for label, rx in SIGNALS if rx.search(text)]


def jobs_of(doc):
    jobs = doc.get("jobs")
    return jobs if isinstance(jobs, dict) else {}


def reusable_target(job):
    """The `uses:` of a job that calls a reusable workflow, else None."""
    uses = job.get("uses") if isinstance(job, dict) else None
    return uses.strip() if isinstance(uses, str) else None


def model_jobs(doc):
    """{job id: why it reaches a model} for one workflow."""
    found = {}
    top_env = signals_in(doc.get("env")) if doc.get("env") else []
    for job_id, job in jobs_of(doc).items():
        if not isinstance(job, dict) or job_id == NOTICE_JOB:
            continue
        why = signals_in(job)
        if reusable_target(job):
            if job.get("secrets") == "inherit":
                why.append("reusable call with secrets: inherit")
        elif top_env:
            why.extend(f"{label} in workflow env" for label in top_env)
        if why:
            found[job_id] = ", ".join(dict.fromkeys(why))
    return found


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
            if mode in ("upstream", "exempt") and note == "-":
                fails.add(f"{REGISTRY}:{lineno}: {workflow} is '{mode}' and needs a reason in the note column")
            rows[workflow] = {"mode": mode, "detail": detail, "note": note, "line": lineno}
            order.append(workflow)
    return rows, order


# ── per-mode checks ──────────────────────────────────────────────────────────

def check_notice_steps(where, steps, fails):
    text = dump(steps)
    if "::notice" not in text:
        fails.add(f"{where}: must print one `::notice` line saying the fleet is paused")
    for var in ("PAUSE_SOURCE", "PAUSE_UNTIL"):
        if var not in text:
            fails.add(f"{where}: the notice must name the pause source and until time ({var})")


def check_job_gate(name, doc, row, fails, table):
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
    for job_id, why in model_jobs(doc).items():
        if job_id not in gated:
            fails.add(f"{name}: job '{job_id}' reaches a model ({why}) but is not in the "
                      f"registry's gated jobs ({row['detail']})")
    if row["mode"] == "job-gate-silent":
        return
    notice = jobs.get(NOTICE_JOB)
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
    check_notice_steps(f"{name}: job '{NOTICE_JOB}'", notice.get("steps") or [], fails)
    env_text = dump({"env": notice.get("env"), "steps": notice.get("steps")})
    for var in ("vars.AGENTS_PAUSE_SOURCE", "vars.AGENTS_PAUSE_UNTIL"):
        if var not in env_text:
            fails.add(f"{name}: job '{NOTICE_JOB}' must read {var}")
    for label, value in PAUSE_VALUES:
        outcome = "runs" if condition_holds(PAUSED, value) else "skipped"
        table.append((name, NOTICE_JOB, label, outcome))


def check_step_gate(name, doc, row, fails, table):
    job_id, _, step_list = row["detail"].partition(":")
    wanted = [s.strip() for s in step_list.split("|") if s.strip()]
    job = jobs_of(doc).get(job_id.strip())
    if not isinstance(job, dict) or not wanted:
        fails.add(f"{name}: mode step-gate needs `<job>:<step>|<step>` naming a real job (got '{row['detail']}')")
        return
    steps = [s for s in (job.get("steps") or []) if isinstance(s, dict)]
    by_name = {str(s.get("name", "")): s for s in steps}
    for step_name in wanted:
        step = by_name.get(step_name)
        if step is None:
            fails.add(f"{name}: registry names step '{step_name}', which job '{job_id}' does not have")
            continue
        ok, _, why = split_condition(norm_if(step.get("if")), GATE)
        if not ok:
            fails.add(f"{name}: step '{step_name}' is not paused by AGENTS_PAUSED: its `if:` {why}")
            continue
        for label, value in PAUSE_VALUES:
            outcome = "runs" if condition_holds(GATE, value) else "skipped"
            table.append((name, f"{job_id}/{step_name}", label, outcome))
    notices = [s for s in steps if split_condition(norm_if(s.get("if")), PAUSED)[0]]
    if not notices:
        fails.add(f"{name}: job '{job_id}' needs a step with `if: {PAUSED}` that logs the pause")
        return
    check_notice_steps(f"{name}: the pause notice step in job '{job_id}'", notices, fails)
    text = dump(notices)
    for var in ("vars.AGENTS_PAUSE_SOURCE", "vars.AGENTS_PAUSE_UNTIL"):
        if var not in text:
            fails.add(f"{name}: the pause notice step in job '{job_id}' must read {var}")


def check_caller(name, doc, row, rows, fails, upstream):
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
    for job_id, why in model_jobs(doc).items():
        if not matches(reusable_target(jobs_of(doc)[job_id])):
            fails.add(f"{name}: job '{job_id}' reaches a model ({why}) outside the reusable "
                      f"the registry names ({target})")


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
    table = []

    for name in order:
        if name not in workflows:
            fails.add(f"{REGISTRY}:{rows[name]['line']}: {name} is not a file under {WORKFLOW_DIR}")

    not_paused = []
    for name, doc in workflows.items():
        row = rows.get(name)
        reaching = model_jobs(doc)
        if row is None:
            if reaching:
                detail = "; ".join(f"job '{j}': {why}" for j, why in reaching.items())
                fails.add(
                    f"{name} can reach a model ({detail}) but has no row in {REGISTRY}. Gate its "
                    f"model-calling job on `{GATE}` and add a job-gate row, or add an exempt row "
                    "with the reason (see AGENTS.md, \"Pausing the agent fleet\").")
            continue
        mode = row["mode"]
        if mode in ("job-gate", "job-gate-silent"):
            check_job_gate(name, doc, row, fails, table)
        elif mode == "step-gate":
            check_step_gate(name, doc, row, fails, table)
        elif mode == "caller":
            check_caller(name, doc, row, rows, fails, upstream=False)
        elif mode == "upstream":
            check_caller(name, doc, row, rows, fails, upstream=True)
            not_paused.append(f"{name} (model call in {row['detail']})")

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
