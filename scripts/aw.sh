#!/usr/bin/env bash
# gh aw — GitHub Agentic Workflows CLI
# Subcommands: compile, run, safe-output
set -euo pipefail

WORKFLOWS_DIR=".github/workflows"
COMMAND="${1:-}"
shift || true

usage() {
  cat >&2 <<'EOF'
Usage:
  aw.sh compile [<file.md>|--all]
  aw.sh run <workflow-name> [--staged]
  aw.sh safe-output apply <workflow-name> <result-file>
EOF
  exit 1
}

# ---------------------------------------------------------------------------
# compile — validate one or all workflow definition files
# ---------------------------------------------------------------------------
cmd_compile() {
  local target="${1:---all}"
  local files=()

  if [[ "$target" == "--all" ]]; then
    while IFS= read -r -d '' f; do
      files+=("$f")
    done < <(find "$WORKFLOWS_DIR" -name '*.md' -print0 2>/dev/null)
    if [[ ${#files[@]} -eq 0 ]]; then
      echo "aw compile: no workflow definitions found in $WORKFLOWS_DIR" >&2
      exit 0
    fi
  else
    files=("$target")
  fi

  local errors=0
  for file in "${files[@]}"; do
    if ! validate_workflow "$file"; then
      errors=$(( errors + 1 ))
    fi
  done

  if [[ $errors -gt 0 ]]; then
    echo "aw compile: $errors file(s) failed validation" >&2
    exit 1
  fi

  echo "aw compile: all workflow definitions are valid"
}

# Validate a single workflow .md file.
# Uses python3 to parse the YAML frontmatter — always available on GitHub Actions runners.
validate_workflow() {
  local file="$1"

  if [[ ! -f "$file" ]]; then
    echo "aw compile: $file: file not found" >&2
    return 1
  fi

  python3 - "$file" <<'PYEOF'
import sys, re

path = sys.argv[1]
with open(path, encoding='utf-8') as f:
    text = f.read()

# Extract YAML frontmatter
m = re.match(r'^---\n(.*?)\n---\n', text, re.DOTALL)
if not m:
    print(f"aw compile: {path}: missing YAML frontmatter", file=sys.stderr)
    sys.exit(1)

import yaml
try:
    fm = yaml.safe_load(m.group(1))
except yaml.YAMLError as e:
    print(f"aw compile: {path}: invalid YAML frontmatter: {e}", file=sys.stderr)
    sys.exit(1)

errors = []

# Required fields
for field in ("name", "trigger", "engine", "permissions"):
    if field not in fm:
        errors.append(f"missing required field: {field!r}")

# Validate engine — accept a model FAMILY (opus|sonnet|haiku|fable), resolved to the
# current id at run time by ai_model_for_family (#1979), or any concrete claude-*
# id an operator pins deliberately. Warn (never fail) on anything else so a new
# provider can be added without a code change.
families = {"opus", "sonnet", "haiku", "fable"}
engine = fm.get("engine", "")
if not isinstance(engine, str):
    # `aw run` cannot use a non-string engine (it keys models.<engine> by it), so
    # this is an error, not a warning. No truth check: null/0/false fail too.
    errors.append(f"engine must be a string, got {type(engine).__name__}")
elif engine and engine not in families and not engine.startswith("claude"):
    print(f"aw compile: {path}: warning: unknown engine {engine!r} (name a family: opus|sonnet|haiku|fable)", file=sys.stderr)

# The `claude` runner takes its model from models.claude; `aw run` hard-fails
# without one, so fail compile the same way. The model itself must be a family or
# a concrete claude-* id. Other runners keep the warn-only rule above, so a new
# provider can still be added without a code change.
if engine == "claude":
    models = fm.get("models") or {}
    val = models.get(engine) if isinstance(models, dict) else None
    if isinstance(val, list):
        val = val[0] if val else None
    if not val:
        errors.append(f"engine {engine!r} needs a model: set models.{engine}: [<family>]")
    elif not isinstance(val, str) or not (val in families or val.startswith("claude-")):
        errors.append(f"models.{engine} must be a family (opus|sonnet|haiku|fable) or a claude-* id, got {val!r}")

# Validate output mode if present
output_mode = fm.get("output")
if output_mode and output_mode not in ("staged", "live"):
    errors.append(f"output must be 'staged' or 'live', got {output_mode!r}")

# Validate trigger has at least one event
trigger = fm.get("trigger") or {}
if not isinstance(trigger, dict) or not trigger:
    errors.append("trigger must be a non-empty mapping of event types")

# Instructions body must not be empty
body = text[m.end():].strip()
if not body:
    errors.append("workflow body (instructions) must not be empty")

if errors:
    for e in errors:
        print(f"aw compile: {path}: {e}", file=sys.stderr)
    sys.exit(1)

print(f"aw compile: {path}: ok")
PYEOF
}

# ---------------------------------------------------------------------------
# run — execute a workflow against GitHub context (or a fixture)
# ---------------------------------------------------------------------------
cmd_run() {
  local name=""
  local staged=false
  local fixture=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --staged)     staged=true ;;
      --fixture)    fixture="${2:-}"; shift ;;
      -*)           echo "aw run: unknown flag $1" >&2; exit 1 ;;
      *)            name="$1" ;;
    esac
    shift
  done

  if [[ -z "$name" ]]; then
    echo "aw run: workflow name required" >&2
    exit 1
  fi

  # Validate workflow name to prevent path traversal
  if [[ ! "$name" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]]; then
    echo "aw run: invalid workflow name: $name" >&2
    exit 1
  fi

  local wf_file="$WORKFLOWS_DIR/${name}.md"
  if [[ ! -f "$wf_file" ]]; then
    echo "aw run: workflow file not found: $wf_file" >&2
    exit 1
  fi

  # Build context from environment or fixture
  local issue_number issue_title issue_body issue_labels issue_url repo
  if [[ -n "$fixture" ]]; then
    # Pass path via env var to avoid injecting user-controlled paths into Python source
    issue_number="$(AW_FIXTURE="$fixture" python3 - <<'PYEOF'
import json, os
with open(os.environ['AW_FIXTURE'], encoding='utf-8') as fh:
    d = json.load(fh)
print(d['issue']['number'])
PYEOF
)"
    issue_title="$(AW_FIXTURE="$fixture" python3 - <<'PYEOF'
import json, os
with open(os.environ['AW_FIXTURE'], encoding='utf-8') as fh:
    d = json.load(fh)
print(d['issue']['title'])
PYEOF
)"
    issue_body="$(AW_FIXTURE="$fixture" python3 - <<'PYEOF'
import json, os
with open(os.environ['AW_FIXTURE'], encoding='utf-8') as fh:
    d = json.load(fh)
print(d['issue']['body'] or '')
PYEOF
)"
    issue_labels="$(AW_FIXTURE="$fixture" python3 - <<'PYEOF'
import json, os
with open(os.environ['AW_FIXTURE'], encoding='utf-8') as fh:
    d = json.load(fh)
print(','.join(l['name'] for l in d['issue'].get('labels', [])))
PYEOF
)"
    issue_url="$(AW_FIXTURE="$fixture" python3 - <<'PYEOF'
import json, os
with open(os.environ['AW_FIXTURE'], encoding='utf-8') as fh:
    d = json.load(fh)
print(d['issue']['html_url'])
PYEOF
)"
    repo="$(AW_FIXTURE="$fixture" python3 - <<'PYEOF'
import json, os
with open(os.environ['AW_FIXTURE'], encoding='utf-8') as fh:
    d = json.load(fh)
print(d['repository']['full_name'])
PYEOF
)"
  else
    issue_number="${ISSUE_NUMBER:-}"
    issue_title="${ISSUE_TITLE:-}"
    issue_body="${ISSUE_BODY:-}"
    issue_labels="${ISSUE_LABELS:-}"
    issue_url="${ISSUE_URL:-https://github.com/${GITHUB_REPOSITORY:-unknown}/issues/${ISSUE_NUMBER:-0}}"
    repo="${GITHUB_REPOSITORY:-unknown}"
  fi

  # Skip guard: read threshold from frontmatter (default 2), skip if label count >= threshold
  local label_count skip_threshold
  label_count="$(AW_LABELS="$issue_labels" python3 - <<'PYEOF'
import os
raw = os.environ.get('AW_LABELS', '').strip()
labels = [l for l in raw.split(',') if l]
print(len(labels))
PYEOF
)"
  skip_threshold="$(python3 - "$wf_file" <<'PYEOF'
import sys, re, yaml
path = sys.argv[1]
with open(path, encoding='utf-8') as f:
    text = f.read()
m = re.match(r'^---\n(.*?)\n---\n', text, re.DOTALL)
fm = yaml.safe_load(m.group(1)) if m else {}
print(fm.get('skip-if-labels-ge', 2))
PYEOF
)"
  if [[ "$label_count" -ge "$skip_threshold" ]]; then
    echo '{"skip": true}'
    return 0
  fi

  # Substitute variables into workflow body.
  # Use a quoted heredoc and env vars so user-controlled issue data cannot
  # escape into Python source code (code injection hotspot).
  local prompt
  prompt="$(AW_ISSUE_NUMBER="$issue_number" \
            AW_ISSUE_TITLE="$issue_title" \
            AW_ISSUE_BODY="$issue_body" \
            AW_ISSUE_LABELS="$issue_labels" \
            AW_ISSUE_URL="$issue_url" \
            AW_REPO="$repo" \
            python3 - "$wf_file" <<'PYEOF'
import sys, re, os

path = sys.argv[1]
with open(path, encoding='utf-8') as f:
    text = f.read()
m = re.match(r'^---\n.*?\n---\n', text, re.DOTALL)
body = text[m.end():] if m else text

labels_val = os.environ.get('AW_ISSUE_LABELS', '')
subs = {
    'ISSUE_NUMBER': os.environ.get('AW_ISSUE_NUMBER', ''),
    'ISSUE_TITLE':  os.environ.get('AW_ISSUE_TITLE', ''),
    'ISSUE_BODY':   os.environ.get('AW_ISSUE_BODY', ''),
    'ISSUE_LABELS': labels_val if labels_val else '(none)',
    'ISSUE_URL':    os.environ.get('AW_ISSUE_URL', ''),
    'REPO':         os.environ.get('AW_REPO', ''),
}
pattern = re.compile('|'.join(re.escape('${' + k + '}') for k in subs))
body = pattern.sub(lambda m: subs[m.group(0)[2:-1]], body)
print(body)
PYEOF
)"

  # Select the model from frontmatter. `engine:` names the RUNNER (e.g. claude);
  # the model family lives in `models.<engine>` (a list, first entry wins). A bare
  # family or concrete id in `engine:` is still honoured for legacy specs.
  local engine model
  engine="$(python3 - "$wf_file" <<'PYEOF'
import sys, re, yaml
path = sys.argv[1]
with open(path, encoding='utf-8') as f:
    text = f.read()
m = re.match(r'^---\n(.*?)\n---\n', text, re.DOTALL)
fm = yaml.safe_load(m.group(1)) or {}
engine = fm.get("engine", "sonnet")
if not isinstance(engine, str):
    print(f"aw run: engine must be a string, got {type(engine).__name__}", file=sys.stderr)
    sys.exit(1)
print(engine)
PYEOF
)"
  model="$(python3 - "$wf_file" <<'PYEOF'
import sys, re, yaml
path = sys.argv[1]
with open(path, encoding='utf-8') as f:
    text = f.read()
m = re.match(r'^---\n(.*?)\n---\n', text, re.DOTALL)
fm = yaml.safe_load(m.group(1)) or {}
engine = fm.get("engine", "sonnet")
models = fm.get("models") or {}
val = models.get(engine) if isinstance(models, dict) and isinstance(engine, str) else None
if isinstance(val, list):
    val = val[0] if val else ""
print(val if isinstance(val, str) else "")
PYEOF
)"

  # The value to pass to Claude: the configured model (models.<engine>), else the
  # engine value itself when it already names a family or concrete id (legacy).
  local want="$model"
  if [[ -z "$want" ]]; then
    case "$engine" in
      opus|sonnet|haiku|fable|claude-*) want="$engine" ;;
      *)
        echo "aw run: no model configured for engine '$engine' (set models.$engine: [<family>])" >&2
        exit 1
        ;;
    esac
  fi

  # Validate the model to prevent command injection before passing to claude.
  if [[ ! "$want" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]]; then
    echo "aw run: invalid model value: $want" >&2
    exit 1
  fi

  # Resolve a model FAMILY (opus|sonnet|haiku|fable) to the current concrete id at run
  # time, so the workflow names a family and never pins a version (#1979). A
  # concrete id (claude-*) an operator set is passed through unchanged.
  local engine_model="$want"
  case "$want" in
    opus|sonnet|haiku|fable)
      # shellcheck source=lib/engine-models.sh
      source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/engine-models.sh"
      engine_model="$(ai_model_for_family "$want")"
      ;;
  esac
  # Re-validate the resolved id: an operator override chain can supply it, so it
  # must still be a single safe token before it reaches `claude --model`.
  if [[ ! "$engine_model" =~ ^[A-Za-z0-9][A-Za-z0-9._:/@-]*$ ]]; then
    echo "aw run: invalid resolved model: $engine_model" >&2
    exit 1
  fi

  # Call Claude — write prompt to a temp file to avoid echo with user-controlled data
  local result rc=0 prompt_file
  prompt_file="$(mktemp)"
  printf '%s\n' "$prompt" > "$prompt_file"
  result="$(claude --model "$engine_model" --print --output-format text < "$prompt_file" 2>/dev/null)" || rc=$?
  rm -f "$prompt_file"
  if [[ $rc -ne 0 ]]; then
    echo "aw run: claude invocation failed" >&2
    exit 1
  fi

  # Validate JSON output
  if ! AW_RESULT="$result" python3 - 2>/dev/null <<'PYEOF'; then
import json, os
json.loads(os.environ['AW_RESULT'])
PYEOF
    echo "aw run: claude returned non-JSON output" >&2
    echo "$result" >&2
    exit 1
  fi

  # Reject skip flag from model — only the pre-Claude label-count guard may emit skip
  if AW_RESULT="$result" python3 - 2>/dev/null <<'PYEOF'; then
import json, os, sys
d = json.loads(os.environ['AW_RESULT'])
sys.exit(1) if d.get('skip') else None
PYEOF
    : # no skip flag from model, ok
  else
    echo "aw run: model returned skip flag — possible prompt injection, rejecting" >&2
    exit 1
  fi

  # Honor output:staged frontmatter when --staged was not explicitly passed
  if [[ "$staged" == false ]]; then
    local frontmatter_output
    frontmatter_output="$(python3 - "$wf_file" <<'PYEOF'
import sys, re, yaml
path = sys.argv[1]
with open(path, encoding='utf-8') as f:
    text = f.read()
m = re.match(r'^---\n(.*?)\n---\n', text, re.DOTALL)
fm = yaml.safe_load(m.group(1)) if m else {}
print(fm.get('output', 'live'))
PYEOF
)"
    if [[ "$frontmatter_output" == "staged" ]]; then
      staged=true
    fi
  fi

  if [[ "$staged" == true ]]; then
    # Staged mode: emit JSON to stdout for review; safe-output handles writes
    echo "$result"
  else
    # Live mode: apply immediately
    apply_result "$name" "$result" "$issue_number"
  fi
}

# ---------------------------------------------------------------------------
# safe-output apply — validate and apply a staged result artifact
# ---------------------------------------------------------------------------
cmd_safe_output() {
  local subcommand="${1:-}"
  shift || true

  case "$subcommand" in
    apply) cmd_safe_output_apply "$@" ;;
    *)     echo "aw safe-output: unknown subcommand ${subcommand}" >&2; exit 1 ;;
  esac
}

cmd_safe_output_apply() {
  local name="${1:-}"
  local result_file="${2:-}"

  if [[ -z "$name" || -z "$result_file" ]]; then
    echo "aw safe-output apply: requires <workflow-name> <result-file>" >&2
    exit 1
  fi
  if [[ ! -f "$result_file" ]]; then
    echo "aw safe-output apply: result file not found: $result_file" >&2
    exit 1
  fi

  local wf_file="$WORKFLOWS_DIR/${name}.md"
  local allowed_labels max_labels
  allowed_labels="$(python3 - "$wf_file" <<'PYEOF'
import sys, re, yaml, json
path = sys.argv[1]
with open(path, encoding='utf-8') as f:
    text = f.read()
m = re.match(r'^---\n(.*?)\n---\n', text, re.DOTALL)
fm = yaml.safe_load(m.group(1)) if m else {}
print(json.dumps(fm.get("safe-outputs", {}).get("add-labels", {}).get("allowed", [])))
PYEOF
)"
  max_labels="$(python3 - "$wf_file" <<'PYEOF'
import sys, re, yaml
path = sys.argv[1]
with open(path, encoding='utf-8') as f:
    text = f.read()
m = re.match(r'^---\n(.*?)\n---\n', text, re.DOTALL)
fm = yaml.safe_load(m.group(1)) if m else {}
print(fm.get("safe-outputs", {}).get("add-labels", {}).get("max", 3))
PYEOF
)"

  # Validate and apply via GitHub API
  python3 - "$result_file" "$allowed_labels" "$max_labels" <<'PYEOF'
import sys, json

result_file  = sys.argv[1]
allowed_set  = set(json.loads(sys.argv[2]))
max_labels   = int(sys.argv[3])

with open(result_file, encoding='utf-8') as f:
    result = json.load(f)

if result.get("skip"):
    print("safe-output: skip flag set — no writes applied")
    sys.exit(0)

labels  = result.get("labels", [])
comment = result.get("comment", "")

# Validate labels is a JSON array of strings before any further checks
if not isinstance(labels, list) or not all(isinstance(l, str) for l in labels):
    print(f"safe-output: rejected — labels must be a JSON array of strings, got {type(labels).__name__}", file=sys.stderr)
    sys.exit(1)

# Validate comment is a non-empty string before any writes occur
if not isinstance(comment, str):
    print(f"safe-output: rejected — comment must be a string, got {type(comment).__name__}", file=sys.stderr)
    sys.exit(1)
if not comment:
    print("safe-output: rejected — empty comment", file=sys.stderr)
    sys.exit(1)

# Validate labels against allowed set
invalid = [l for l in labels if l not in allowed_set]
if invalid:
    print(f"safe-output: rejected — labels not in allowed set: {invalid}", file=sys.stderr)
    sys.exit(1)
if len(labels) > max_labels:
    print(f"safe-output: rejected — more than {max_labels} labels: {labels}", file=sys.stderr)
    sys.exit(1)

print(f"safe-output: labels={labels}, comment length={len(comment)}")
print("safe-output: validation passed — ready for API writes")
PYEOF

  # Apply writes via gh CLI
  local issue_number="${ISSUE_NUMBER:-}"
  local repo="${GITHUB_REPOSITORY:-}"

  if [[ -z "$issue_number" || -z "$repo" ]]; then
    echo "safe-output apply: ISSUE_NUMBER and GITHUB_REPOSITORY must be set for live writes" >&2
    exit 1
  fi

  # Validate inputs before passing to gh CLI to prevent command injection
  if [[ ! "$issue_number" =~ ^[0-9]+$ ]]; then
    echo "safe-output apply: ISSUE_NUMBER must be a positive integer, got: $issue_number" >&2
    exit 1
  fi
  if [[ ! "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
    echo "safe-output apply: GITHUB_REPOSITORY has unexpected format: $repo" >&2
    exit 1
  fi

  local result_json
  result_json="$(cat "$result_file")"

  # Apply labels — pass as comma-separated string so the argument stays quoted
  local labels_csv
  labels_csv="$(AW_RESULT_JSON="$result_json" python3 - <<'PYEOF'
import json, os
r = json.loads(os.environ['AW_RESULT_JSON'])
if not r.get('skip'):
    print(','.join(r.get('labels', [])))
PYEOF
)"
  if [[ -n "$labels_csv" ]]; then
    gh issue edit "$issue_number" --repo "$repo" --add-label "$labels_csv"
  fi

  # Post comment via temp file to avoid ARG_MAX limits on large comment bodies
  local comment_file
  comment_file="$(mktemp)"
  python3 - "$result_file" <<'PYEOF' > "$comment_file"
import json, sys
with open(sys.argv[1], encoding='utf-8') as f:
    r = json.load(f)
c = r.get('comment', '') if not r.get('skip') else ''
sys.stdout.write(c)
PYEOF
  if [[ -s "$comment_file" ]]; then
    gh issue comment "$issue_number" --repo "$repo" --body-file "$comment_file"
  fi
  rm -f "$comment_file"

  echo "safe-output apply: done"
}

# Apply result inline (live mode, called from cmd_run)
apply_result() {
  local name="$1" result="$2" issue_number="$3"
  local tmp
  tmp="$(mktemp)"
  printf '%s\n' "$result" > "$tmp"
  ISSUE_NUMBER="$issue_number" cmd_safe_output_apply "$name" "$tmp"
  rm -f "$tmp"
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
case "$COMMAND" in
  compile)      cmd_compile "$@" ;;
  run)          cmd_run "$@" ;;
  safe-output)  cmd_safe_output "$@" ;;
  "")           usage ;;
  *)            echo "aw.sh: unknown command '$COMMAND'" >&2; usage ;;
esac
