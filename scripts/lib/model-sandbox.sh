# shellcheck shell=bash
# scripts/lib/model-sandbox.sh — run review-model CLIs as a separate, unprivileged
# user. The review orchestrator keeps its GitHub credentials; a model call gets
# only its own engine key, read access to the pre-fed context, and no shell tool.
#
# Enabled by PR_REVIEW_MODEL_USER (set by .github/workflows/pr-review.yml, created
# by scripts/model-sandbox-setup.sh). Unset, every function here is inert and
# engine.sh behaves as before, so the dev-lead and eval paths are unaffected.

# Installed by scripts/model-sandbox-setup.sh; readable by the model user.
MODEL_SANDBOX_ROOT="${MODEL_SANDBOX_ROOT:-/opt/pr-review-model}"
MODEL_SANDBOX_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# review-one-pr.sh's working directory: pre-fed context and earlier tiers' results.
MODEL_SANDBOX_CONTEXT_DIR="${MODEL_SANDBOX_CONTEXT_DIR:-/tmp/cascade}"

# The only tools a sandboxed Claude call has. Read-only, with no shell and no
# network tool, so the one secret it holds (its own key) has no way out.
MODEL_SANDBOX_TOOLS="Read,Grep,Glob"

# Variables the prompts name that are safe to hand to the model as text. An
# allowlist, so a new secret in the job environment can never be rendered.
MODEL_SANDBOX_PROMPT_VARS="PR_URL PR_HEAD_SHA PR_ORG DRY_RUN REVIEW_CYCLE MAX_REVIEW_CYCLES REVIEW_MODE
AI_DELEGATION_ENABLED TRIAGE_RESULT TRIAGE_TYPE PRIOR_REVIEW_SHA PRIOR_REVIEW_FILE PRIOR_REVIEW_BODY
DOWNSTREAM_IMPACT_FILE SAFETY_CHECKS_FILE FEWSHOT_FILE SYMBOL_CONTEXT_FILE ADVISORY_BOT_FEEDBACK_FILE
NON_REQUIRED_CI_FAILURES PR_CONTEXT_METADATA_FILE PR_CONTEXT_DIFF_FILE PR_CONTEXT_EXTRAS_FILE
FINAL_RESULT FINAL_TIER DEEP_RESULT DUCK_RESULT TIER2_RESULT ENGINE_LABEL ENGINE_SINGLE_LABEL
DUCK_ENGINE DUCK_MODEL"

# Secrets the job environment can hold. Names only; used to refuse a verdict that
# carries one of the values and by the self-test.
MODEL_SANDBOX_SECRET_VARS="GH_TOKEN GITHUB_TOKEN COPILOT_GITHUB_TOKEN CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_API_KEY
GEMINI_API_KEY GOOGLE_API_KEY GOOGLE_API_KEY_2 GOOGLE_API_KEY_3 GOOGLE_API_KEY_4"

model_sandbox_enabled() { [ -n "${PR_REVIEW_MODEL_USER:-}" ]; }

# model_sandbox_require — non-zero when this run must be sandboxed and is not.
model_sandbox_require() {
  if [ "${PR_REVIEW_REQUIRE_MODEL_SANDBOX:-false}" = "true" ] && ! model_sandbox_enabled; then
    echo "::error::PR_REVIEW_REQUIRE_MODEL_SANDBOX is set but PR_REVIEW_MODEL_USER is not — refusing to run a review model"
    return 1
  fi
  return 0
}

_model_sandbox_home() { printf '%s' "${MODEL_SANDBOX_HOME:-/home/$PR_REVIEW_MODEL_USER}"; }
_model_sandbox_path() { printf '%s/cli/bin:%s' "$MODEL_SANDBOX_ROOT" "$PATH"; }

# _model_sandbox_as <cmd...> — run <cmd> as the model user with a reset environment.
_model_sandbox_as() {
  sudo -n -u "$PR_REVIEW_MODEL_USER" env \
    PATH="$(_model_sandbox_path)" HOME="$(_model_sandbox_home)" "$@"
}

# model_sandbox_exec <cmd...> — start a model CLI (behind its `timeout` wrapper) as
# the model user. stdin/stdout/stderr are the caller's. Only that engine's key
# crosses, by name through sudo's environment, so no value lands on a command line.
model_sandbox_exec() {
  local arg cli="" keep="" prev=""
  local -a cmd=()
  for arg in "$@"; do
    if [ -z "$cli" ]; then
      case "$arg" in claude | gemini | gh) cli="$arg" ;; esac
    fi
    # The caller's checkout stays out of reach; the sandbox directory stands in.
    [ "$prev" = "--add-dir" ] && arg="$MODEL_SANDBOX_ROOT/cwd"
    cmd+=("$arg")
    prev="$arg"
  done
  case "$cli" in
    claude) keep="CLAUDE_CODE_OAUTH_TOKEN,ANTHROPIC_API_KEY" ;;
    gemini) keep="GEMINI_API_KEY,GOOGLE_API_KEY" ;;
    *)
      # Copilot authenticates with a user PAT, which cannot be withheld from it.
      echo "::error::engine '${cli:-unknown}' cannot run in the review model sandbox" >&2
      return 1
      ;;
  esac
  # Tiers read earlier tiers' results and pre-fed files from here.
  chmod -R a+rX "$MODEL_SANDBOX_CONTEXT_DIR" 2>/dev/null || true
  (
    cd "$MODEL_SANDBOX_ROOT/cwd" || exit 1
    exec sudo -n -u "$PR_REVIEW_MODEL_USER" --preserve-env="$keep" env \
      PATH="$(_model_sandbox_path)" HOME="$(_model_sandbox_home)" TMPDIR=/tmp \
      DISABLE_AUTOUPDATER=1 CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD=1 "${cmd[@]}"
  )
}

# model_sandbox_reap — stop anything still running as the model user. Called before
# a verdict is acted on, not after each call: the deep and duck tiers run in parallel.
model_sandbox_reap() {
  model_sandbox_enabled || return 0
  sudo -n pkill -KILL -u "$PR_REVIEW_MODEL_USER" 2>/dev/null || true
  return 0
}

# model_sandbox_render_prompt <prompt_file> <out_file> — the rules, the runtime
# values the prompt refers to by name, then the prompt. A sandboxed model has no
# shell to expand a variable with.
model_sandbox_render_prompt() {
  local prompt_file="$1" out_file="$2" name value
  {
    cat "$MODEL_SANDBOX_LIB_DIR/../../prompts/pr-review/model-sandbox.md"
    printf '\n## Runtime values\n\n'
    for name in $MODEL_SANDBOX_PROMPT_VARS; do
      value="${!name-}"
      [ -n "$value" ] && printf -- '- `$%s`: %s\n' "$name" "$value"
    done
    printf '\n---\n\n'
    cat "$prompt_file"
  } > "$out_file"
}

# model_sandbox_call <run_fn> <prompt_file> [args...] — one sandboxed tier: render
# the prompt, restrict the tools, and write the verdict file from the model's
# output, since the model has no way to write one. Stdout still reaches the caller.
model_sandbox_call() {
  local run_fn="$1" prompt_file="$2"
  shift 2
  local rendered out rc=0
  rendered="$(mktemp)" && out="$(mktemp)" || return 1
  if ! model_sandbox_render_prompt "$prompt_file" "$rendered"; then
    rm -f "$rendered" "$out"
    return 1
  fi
  # Seen by the run function through dynamic scope.
  local -a _ENGINE_TOOL_ARGS=(--tools "$MODEL_SANDBOX_TOOLS")
  local _ENGINE_REVIEW_TOOLS="$MODEL_SANDBOX_TOOLS"
  # shellcheck disable=SC2034 # read by _mcp_review_flags
  local REVIEW_MCP_CONFIG=""
  [ -n "${OUTPUT_FILE:-}" ] && rm -f "$OUTPUT_FILE"
  "$run_fn" "$rendered" "$@" > "$out" || rc=$?
  cat "$out"
  if [ "$rc" -eq 0 ] && [ -n "${OUTPUT_FILE:-}" ]; then
    extract_verdict_json "$out" "$OUTPUT_FILE" || true
    [ -s "$OUTPUT_FILE" ] || rm -f "$OUTPUT_FILE"
  fi
  rm -f "$rendered" "$out"
  return "$rc"
}

# model_sandbox_selftest — prove the boundary on this runner before any model runs.
# Every probe that should fail is checked, and any surprise is a hard failure.
model_sandbox_selftest() {
  local failed=0 name target cli

  _model_sandbox_as true || {
    echo "::error::model sandbox: cannot run as '$PR_REVIEW_MODEL_USER'"
    return 1
  }

  if _model_sandbox_as cat "/proc/$$/environ" >/dev/null 2>&1; then
    echo "::error::model sandbox: the model user can read the orchestrator's environment"
    failed=1
  fi
  for target in "${GITHUB_ENV:-}" "${GITHUB_PATH:-}" "${GITHUB_OUTPUT:-}" "${GITHUB_STEP_SUMMARY:-}" \
                "${GITHUB_WORKSPACE:-}" "${GITHUB_WORKSPACE:+$GITHUB_WORKSPACE/scripts/post-pr-review.sh}" \
                "$MODEL_SANDBOX_ROOT/cli" "$MODEL_SANDBOX_ROOT/cwd" "$MODEL_SANDBOX_CONTEXT_DIR"; do
    [ -n "$target" ] && [ -e "$target" ] || continue
    if _model_sandbox_as test -w "$target"; then
      echo "::error::model sandbox: the model user can write $target"
      failed=1
    fi
  done
  for name in $MODEL_SANDBOX_SECRET_VARS; do
    if _model_sandbox_as printenv "$name" >/dev/null 2>&1; then
      echo "::error::model sandbox: $name reached the model user"
      failed=1
    fi
  done
  if [ -n "${GITHUB_WORKSPACE:-}" ] && [ -d "$GITHUB_WORKSPACE/.git" ] \
    && git -C "$GITHUB_WORKSPACE" config --get-regexp 'extraheader' >/dev/null 2>&1; then
    echo "::error::model sandbox: the checkout kept a credential (persist-credentials must be false)"
    failed=1
  fi
  for cli in claude gemini; do
    command -v "$cli" >/dev/null 2>&1 || continue
    if ! _model_sandbox_as "$cli" --version >/dev/null 2>&1; then
      echo "::error::model sandbox: the model user cannot run $cli"
      failed=1
    fi
  done
  return "$failed"
}

# model_sandbox_validate_verdict <verdict_file> <head_sha> — treat a model's verdict
# as data. Refuses anything malformed or carrying a known secret, then rewrites the
# file to the known fields with a marker built here, never taken from model text.
model_sandbox_validate_verdict() {
  local file="$1" sha="$2" name value tmp
  if [ -L "$file" ] || [ ! -f "$file" ]; then
    echo "::error::verdict is not a regular file"
    return 1
  fi
  if [ "$(wc -c < "$file")" -gt 262144 ]; then
    echo "::error::verdict is larger than the 256 KiB limit"
    return 1
  fi
  for name in $MODEL_SANDBOX_SECRET_VARS; do
    value="${!name-}"
    [ "${#value}" -ge 8 ] || continue
    if printf '%s\n' "$value" | grep -qFf - "$file"; then
      echo "::error::verdict contains the value of a credential; refusing to post it"
      return 1
    fi
  done
  tmp="$(mktemp)" || return 1
  if ! jq -e --arg sha "$sha" '
      def marker: "<!-- pr-review-agent v1 sha=\($sha) decision=\(if .decision == "approve" then "approved" else "escalated" end) risk=\(.risk) -->";
      if type != "object" then error("not an object") else . end
      | if (.decision | IN("approve", "escalate", "skip")) then . else error("bad decision") end
      | if .decision == "skip" then
          {decision, sha: $sha, reason: ((.reason // "unspecified") | tostring | .[0:200])}
        else
          if (.risk | IN("LOW", "MEDIUM", "HIGH")) then . else error("bad risk") end
          | if (.body | type) == "string" and (.body | length) <= 60000 then . else error("bad body") end
          | {
              decision, risk, sha: $sha,
              pr: ((.pr // "") | tostring),
              mode: ((.mode // "") | tostring),
              summary: ((.summary // "") | tostring | .[0:4000]),
              findings: (.findings // []),
              metadata_only: (.metadata_only == true),
              escalate_to_ai: (.escalate_to_ai == true),
              body: (marker + "\n\n" + (.body | gsub("<!--[\\s\\S]*?-->"; "") | gsub("<!--[\\s\\S]*$"; "") | sub("^\\s+"; "")))
            }
        end' "$file" > "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    echo "::error::verdict failed validation"
    return 1
  fi
  mv "$tmp" "$file"
}
