#!/usr/bin/env bats
# Review models run as an unprivileged user with only their own engine key and
# read-only tools, and their verdicts are treated as data
# (scripts/lib/model-sandbox.sh).

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  export REPO_ROOT
  export TEST_DIR="$BATS_TEST_TMPDIR"
  mkdir -p "$TEST_DIR/bin" "$TEST_DIR/root/cwd" "$TEST_DIR/root/cli/bin"
  export MODEL_SANDBOX_ROOT="$TEST_DIR/root"
  export MODEL_SANDBOX_GEMINI_SETTINGS="$TEST_DIR/etc/settings.json"
  mkdir -p "$TEST_DIR/etc"; echo '{}' > "$MODEL_SANDBOX_GEMINI_SETTINGS"
  export SUDO_LOG="$TEST_DIR/sudo.log"; : > "$SUDO_LOG"
  export CLI_ENV="$TEST_DIR/cli_env"
  export CLI_ARGS="$TEST_DIR/cli_args"
  export CLI_STDIN="$TEST_DIR/cli_stdin"
  export SHA="deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
  export PR_HEAD_SHA="$SHA"
  export PR_URL="https://github.com/combsmith/example/pull/7"
  export CLI_OUTPUT='{"decision":"approve","risk":"LOW","body":"fine"}'

  # sudo stub: accepts only the forms the code uses, and resets the environment the
  # way the real one does, keeping just --preserve-env names.
  cat > "$TEST_DIR/bin/sudo" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SUDO_LOG"
keep=""
[ "${1:-}" = "-n" ] || { echo "sudo: a password is required" >&2; exit 1; }
shift
if [ "${1:-}" = "pkill" ] || [ "${1:-}" = "useradd" ]; then exit 0; fi
if [ "${1:-}" != "-u" ]; then
  [ -n "${SETUP_LOG_ONLY:-}" ] && { [ "${1:-}" = "tee" ] && cat >/dev/null; exit 0; }
  exit 1
fi
shift 2
case "${1:-}" in --preserve-env=*) keep="${1#--preserve-env=}"; shift ;; esac
if [ -n "${PROBE_SUCCEEDS:-}" ] && [[ "$*" == *"$PROBE_SUCCEEDS"* ]]; then exit 0; fi
case "$*" in
  *" test -w "*) exit 1 ;;
  *" test -r "*) exit 1 ;;
  *" test -x "*) exit 1 ;;
  *" cat /proc/"*) exit 1 ;;
  *" printenv "*) exit 1 ;;
esac
args=()
IFS=',' read -ra names <<< "$keep"
for n in "${names[@]}"; do
  [ -n "${!n+x}" ] && args+=("$n=${!n}")
done
args+=("PATH=$PATH" "CLI_ENV=$CLI_ENV" "CLI_ARGS=$CLI_ARGS" "CLI_STDIN=$CLI_STDIN" "CLI_OUTPUT=$CLI_OUTPUT")
exec env -i "${args[@]}" "$@"
STUB
  for cli in claude gemini; do
    cat > "$TEST_DIR/bin/$cli" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then echo 1.0; exit 0; fi
env > "$CLI_ENV"
printf '%s\n' "$*" > "$CLI_ARGS"
cat > "$CLI_STDIN"
printf '%s\n' "$CLI_OUTPUT"
STUB
  done
  cat > "$TEST_DIR/bin/timeout" <<'STUB'
#!/usr/bin/env bash
shift 2
exec "$@"
STUB
  chmod +x "$TEST_DIR/bin/"*
  export PATH="$TEST_DIR/bin:$PATH"

  cd "$TEST_DIR" || return 1
  printf 'review the PR\n' > "$TEST_DIR/prompt.md"
  export GH_TOKEN="ghp_secretvalue_orchestrator"
  export COPILOT_GITHUB_TOKEN="ghp_secretvalue_owner"
  export CLAUDE_CODE_OAUTH_TOKEN="oauth_secretvalue_model"
  export GEMINI_API_KEY="gemini_secretvalue_key"
  export GOOGLE_API_KEY_2="gemini_secretvalue_rotation"
  export REVIEW_ENGINE=claude
  export ENGINE_DEEP_MODEL=deep-model ENGINE_KILL_AFTER=5 DEEP_TIMEOUT_SEC=60 DUCK_TIMEOUT_SEC=60
  unset TOKEN_LOG_FILE REVIEW_MCP_CONFIG

  # shellcheck source=/dev/null
  source "$REPO_ROOT/scripts/engine.sh"
  # shellcheck source=/dev/null
  source "$REPO_ROOT/scripts/lib/pr-context-prefetch.sh"
  export PR_REVIEW_MODEL_USER=pr-review-model
  export DUCK_ENGINE=claude
}

verdict() { printf '%s' "$1" > "$TEST_DIR/v.json"; echo "$TEST_DIR/v.json"; }

# ── The boundary ─────────────────────────────────────────────────────────────

@test "a sandboxed Claude call gets its own key and no other credential" {
  _engine_child timeout --kill-after=5 60 claude --print < "$TEST_DIR/prompt.md"
  grep -q '^CLAUDE_CODE_OAUTH_TOKEN=' "$CLI_ENV"
  run grep -E 'GH_TOKEN|COPILOT_GITHUB_TOKEN|GEMINI_API_KEY|GOOGLE_API_KEY' "$CLI_ENV"
  [ "$status" -eq 1 ]
}

@test "no credential value appears on the sudo command line" {
  _engine_child timeout --kill-after=5 60 claude --print < "$TEST_DIR/prompt.md"
  run grep -q 'secretvalue' "$SUDO_LOG"
  [ "$status" -eq 1 ]
  grep -q -- '-u pr-review-model --preserve-env=' "$SUDO_LOG"
}

@test "--add-dir points at the sandbox directory, never the caller's checkout" {
  _engine_child timeout --kill-after=5 60 claude --print --add-dir "$TEST_DIR/checkout" --model m < "$TEST_DIR/prompt.md"
  grep -qF -- "--add-dir $MODEL_SANDBOX_ROOT/cwd --model m" "$CLI_ARGS"
  run grep -q 'checkout' "$CLI_ARGS"
  [ "$status" -eq 1 ]
  grep -q '^CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD=1$' "$CLI_ENV"
}

@test "Gemini is refused in the sandbox unless explicitly allowed" {
  run _engine_child timeout --kill-after=5 60 gemini --prompt "" < "$TEST_DIR/prompt.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Gemini is not enabled"* ]]
  [ ! -s "$SUDO_LOG" ]
}

@test "setup restricts the engine lists to Claude" {
  export SETUP_LOG_ONLY=1 MODEL_SANDBOX_HOME="$TEST_DIR/home" HOME="$TEST_DIR"
  export GITHUB_ENV="$TEST_DIR/github_env"; : > "$GITHUB_ENV"
  export AI_ENGINES=claude,gemini AI_DUCK_ENGINE=gemini,claude
  run bash "$REPO_ROOT/scripts/model-sandbox-setup.sh"
  echo "$output" >&2
  [ "$status" -eq 0 ]
  grep -qx 'AI_ENGINES=claude' "$GITHUB_ENV"
  grep -qx 'AI_DUCK_ENGINE=claude' "$GITHUB_ENV"
  grep -qx 'REVIEW_ENGINE=claude' "$GITHUB_ENV"
}

@test "setup leaves the engine lists alone when Gemini is explicitly allowed" {
  export SETUP_LOG_ONLY=1 MODEL_SANDBOX_HOME="$TEST_DIR/home" HOME="$TEST_DIR" MODEL_SANDBOX_ALLOW_GEMINI=true
  export GITHUB_ENV="$TEST_DIR/github_env"; : > "$GITHUB_ENV"
  run bash "$REPO_ROOT/scripts/model-sandbox-setup.sh"
  echo "$output" >&2
  [ "$status" -eq 0 ]
  [ ! -s "$GITHUB_ENV" ]
}

@test "without GITHUB_ENV setup still succeeds and Gemini is still refused at run time" {
  export SETUP_LOG_ONLY=1 MODEL_SANDBOX_HOME="$TEST_DIR/home"
  unset GITHUB_ENV
  HOME="$TEST_DIR" run bash "$REPO_ROOT/scripts/model-sandbox-setup.sh"
  [ "$status" -eq 0 ]
  run _engine_child timeout --kill-after=5 60 gemini --prompt "" < "$TEST_DIR/prompt.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Gemini is not enabled"* ]]
}

@test "Gemini is told to trust the sandbox working directory, or it refuses to start" {
  export MODEL_SANDBOX_ALLOW_GEMINI=true
  _engine_child timeout --kill-after=5 60 gemini --prompt "" < "$TEST_DIR/prompt.md"
  grep -q '^GEMINI_CLI_TRUST_WORKSPACE=true$' "$CLI_ENV"
}

@test "a sandboxed Gemini call gets only the current Gemini key" {
  export MODEL_SANDBOX_ALLOW_GEMINI=true
  _engine_child timeout --kill-after=5 60 gemini --prompt "" < "$TEST_DIR/prompt.md"
  grep -q '^GEMINI_API_KEY=' "$CLI_ENV"
  run grep -E 'GH_TOKEN|COPILOT_GITHUB_TOKEN|CLAUDE_CODE_OAUTH_TOKEN|GOOGLE_API_KEY_2' "$CLI_ENV"
  [ "$status" -eq 1 ]
}

@test "Copilot is refused in the sandbox, because its auth is a user PAT" {
  run _engine_child timeout --kill-after=5 60 gh copilot < "$TEST_DIR/prompt.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"cannot run in the review model sandbox"* ]]
  [ ! -s "$SUDO_LOG" ]
}

@test "without a model user nothing changes: no sudo, the caller's environment" {
  unset PR_REVIEW_MODEL_USER
  _engine_child claude --print < "$TEST_DIR/prompt.md"
  [ ! -s "$SUDO_LOG" ]
  grep -q '^GH_TOKEN=' "$CLI_ENV"
  grep -q '^CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD=1$' "$CLI_ENV"
}

@test "a required sandbox that is not configured refuses to run" {
  unset PR_REVIEW_MODEL_USER
  export PR_REVIEW_REQUIRE_MODEL_SANDBOX=true
  run model_sandbox_require
  [ "$status" -eq 1 ]
  export PR_REVIEW_MODEL_USER=pr-review-model
  run model_sandbox_require
  [ "$status" -eq 0 ]
}

# ── The tiers ────────────────────────────────────────────────────────────────

@test "run_agentic in the sandbox has read-only tools and no shell" {
  export OUTPUT_FILE="$TEST_DIR/out.json"
  run_agentic "$TEST_DIR/prompt.md" deep-model deep >/dev/null
  grep -q -- '--tools Read,Grep,Glob' "$CLI_ARGS"
  grep -q -- '--allowed-tools Read,Grep,Glob' "$CLI_ARGS"
  run grep -q 'Bash' "$CLI_ARGS"
  [ "$status" -eq 1 ]
}

@test "run_agentic writes the verdict from the model's output and still prints it" {
  export OUTPUT_FILE="$TEST_DIR/out.json"
  echo '{"decision":"stale"}' > "$OUTPUT_FILE"
  run run_agentic "$TEST_DIR/prompt.md" deep-model deep
  [ "$status" -eq 0 ]
  [[ "$output" == *'"decision":"approve"'* ]]
  [ "$(jq -r .decision "$OUTPUT_FILE")" = "approve" ]
}

@test "no verdict in the model's output leaves no verdict file" {
  export OUTPUT_FILE="$TEST_DIR/out.json"
  export CLI_OUTPUT="I could not finish."
  run run_agentic "$TEST_DIR/prompt.md" deep-model deep
  [ ! -e "$OUTPUT_FILE" ]
}

@test "the rendered prompt has the rules and values, and no secret" {
  export OUTPUT_FILE="$TEST_DIR/out.json" TRIAGE_RESULT='{"escalate":false}'
  run_agentic "$TEST_DIR/prompt.md" deep-model deep >/dev/null
  grep -q 'no shell' "$CLI_STDIN"
  grep -qF "\`\$PR_HEAD_SHA\`: $SHA" "$CLI_STDIN"
  grep -qF '`$TRIAGE_RESULT`: {"escalate":false}' "$CLI_STDIN"
  grep -q 'review the PR' "$CLI_STDIN"
  run grep -q 'secretvalue' "$CLI_STDIN"
  [ "$status" -eq 1 ]
}

@test "an MCP config cannot widen the sandboxed tools" {
  printf '{}' > "$TEST_DIR/mcp.json"
  export REVIEW_MCP_CONFIG="$TEST_DIR/mcp.json" REVIEW_MCP_ALLOWED_TOOLS='mcp__github__*'
  export OUTPUT_FILE="$TEST_DIR/out.json"
  run_agentic "$TEST_DIR/prompt.md" deep-model deep >/dev/null
  run grep -E 'mcp' "$CLI_ARGS"
  [ "$status" -eq 1 ]
}

@test "the Claude duck in the sandbox has read-only tools and no shell" {
  export OUTPUT_FILE="$TEST_DIR/duck.json"
  run_duck "$TEST_DIR/prompt.md" duck-model >/dev/null
  grep -q -- '--tools Read,Grep,Glob' "$CLI_ARGS"
  run grep -q 'Bash' "$CLI_ARGS"
  [ "$status" -eq 1 ]
  [ "$(jq -r .decision "$OUTPUT_FILE")" = "approve" ]
}

@test "a dry run is sandboxed the same way" {
  export DRY_RUN=true OUTPUT_FILE="$TEST_DIR/out.json"
  run_agentic "$TEST_DIR/prompt.md" deep-model deep >/dev/null
  grep -q -- '-u pr-review-model' "$SUDO_LOG"
  run grep -q '^GH_TOKEN=' "$CLI_ENV"
  [ "$status" -eq 1 ]
}

@test "outside the sandbox run_agentic keeps its default tools" {
  unset PR_REVIEW_MODEL_USER
  export OUTPUT_FILE="$TEST_DIR/out.json"
  run_agentic "$TEST_DIR/prompt.md" deep-model deep >/dev/null
  grep -q -- '--allowed-tools Bash,Read,Grep,Glob' "$CLI_ARGS"
  run grep -q -- '--tools' "$CLI_ARGS"
  [ "$status" -eq 1 ]
}

@test "reap stops everything left running as the model user" {
  model_sandbox_reap
  grep -q 'pkill -KILL -u pr-review-model' "$SUDO_LOG"
}

# ── The self-test ────────────────────────────────────────────────────────────

@test "self-test passes when the boundary holds" {
  run model_sandbox_selftest
  echo "$output" >&2
  [ "$status" -eq 0 ]
}

@test "self-test fails when the model user can read the orchestrator's environment" {
  export PROBE_SUCCEEDS="cat /proc/"
  run model_sandbox_selftest
  [ "$status" -eq 1 ]
  [[ "$output" == *"read the orchestrator"* ]]
}

@test "self-test fails when the model user can write a runner command file" {
  export GITHUB_ENV="$TEST_DIR/github_env"; : > "$GITHUB_ENV"
  export PROBE_SUCCEEDS="test -w $GITHUB_ENV"
  run model_sandbox_selftest
  [ "$status" -eq 1 ]
  [[ "$output" == *"can write $GITHUB_ENV"* ]]
}

@test "self-test fails when the model user can write the posting script" {
  export GITHUB_WORKSPACE="$TEST_DIR/ws"; mkdir -p "$GITHUB_WORKSPACE/scripts"
  : > "$GITHUB_WORKSPACE/scripts/post-pr-review.sh"
  export PROBE_SUCCEEDS="test -w $GITHUB_WORKSPACE/scripts/post-pr-review.sh"
  run model_sandbox_selftest
  [ "$status" -eq 1 ]
}

@test "self-test fails when the model user can read a runner command file" {
  export GITHUB_ENV="$TEST_DIR/github_env"; : > "$GITHUB_ENV"
  export PROBE_SUCCEEDS="test -r $GITHUB_ENV"
  run model_sandbox_selftest
  [ "$status" -eq 1 ]
  [[ "$output" == *"can read $GITHUB_ENV"* ]]
}

@test "self-test fails when the model user can read the gh config" {
  export HOME="$TEST_DIR/runner-home"; mkdir -p "$HOME/.config/gh"; : > "$HOME/.config/gh/hosts.yml"
  export PROBE_SUCCEEDS="test -r $HOME/.config/gh/hosts.yml"
  run model_sandbox_selftest
  [ "$status" -eq 1 ]
  [[ "$output" == *"hosts.yml"* ]]
}

@test "self-test fails when the model user can enter the runner's home" {
  export HOME="$TEST_DIR/runner-home"; mkdir -p "$HOME"
  export PROBE_SUCCEEDS="test -x $HOME"
  run model_sandbox_selftest
  [ "$status" -eq 1 ]
  [[ "$output" == *"can enter $HOME"* ]]
}

@test "self-test fails when the model user can enter the runner's temp directory" {
  export RUNNER_TEMP="$TEST_DIR/runner-temp"; mkdir -p "$RUNNER_TEMP"
  export PROBE_SUCCEEDS="test -x $RUNNER_TEMP"
  run model_sandbox_selftest
  [ "$status" -eq 1 ]
  [[ "$output" == *"can enter $RUNNER_TEMP"* ]]
}

@test "self-test fails when Gemini's tool limits are missing" {
  rm -f "$MODEL_SANDBOX_GEMINI_SETTINGS"
  run model_sandbox_selftest
  [ "$status" -eq 1 ]
  [[ "$output" == *"tool limits are missing"* ]]
}

@test "self-test fails when the model user can change Gemini's tool limits" {
  export PROBE_SUCCEEDS="test -w $MODEL_SANDBOX_GEMINI_SETTINGS"
  run model_sandbox_selftest
  [ "$status" -eq 1 ]
  [[ "$output" == *"change Gemini's tool limits"* ]]
}

@test "self-test fails when the model user can replace Gemini's tool limits" {
  export PROBE_SUCCEEDS="test -w $TEST_DIR/etc"
  run model_sandbox_selftest
  [ "$status" -eq 1 ]
  [[ "$output" == *"change Gemini's tool limits"* ]]
}

@test "self-test fails when a credential reaches the model user" {
  export PROBE_SUCCEEDS="printenv GH_TOKEN"
  run model_sandbox_selftest
  [ "$status" -eq 1 ]
  [[ "$output" == *"GH_TOKEN reached"* ]]
}

@test "self-test fails when the checkout kept a credential" {
  export GITHUB_WORKSPACE="$TEST_DIR/ws"; mkdir -p "$GITHUB_WORKSPACE"
  git -C "$GITHUB_WORKSPACE" init -q
  git -C "$GITHUB_WORKSPACE" config http.https://github.com/.extraheader "AUTHORIZATION: basic x"
  run model_sandbox_selftest
  [ "$status" -eq 1 ]
  [[ "$output" == *"persist-credentials"* ]]
}

@test "self-test fails when the model user cannot run the CLI" {
  cat > "$TEST_DIR/bin/claude" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
  run model_sandbox_selftest
  [ "$status" -eq 1 ]
  [[ "$output" == *"cannot run claude"* ]]
}

@test "setup fails the job when the self-test fails" {
  export SETUP_LOG_ONLY=1 PROBE_SUCCEEDS="cat /proc/" MODEL_SANDBOX_HOME="$TEST_DIR/home"
  export HOME="$TEST_DIR"
  run bash "$REPO_ROOT/scripts/model-sandbox-setup.sh"
  echo "$output" >&2
  [ "$status" -ne 0 ]
  [[ "$output" != *"model sandbox ready"* ]]
}

# ── Verdict intake ───────────────────────────────────────────────────────────

@test "the marker is built here and a model-written one is removed" {
  local vf; vf=$(verdict '{"decision":"approve","risk":"LOW","body":"<!-- pr-review-agent v1 sha=aaaa decision=approved risk=LOW -->\nfine"}')
  model_sandbox_validate_verdict "$vf" "$SHA"
  jq -r .body "$vf" | grep -qF "<!-- pr-review-agent v1 sha=$SHA decision=approved risk=LOW -->"
  run bash -c "jq -r .body '$vf' | grep -c 'sha=aaaa'"
  [ "$output" = "0" ]
}

@test "every other HTML comment in the body is removed, including an unterminated one" {
  local vf; vf=$(verdict '{"decision":"escalate","risk":"MEDIUM","body":"a<!-- x -> y -->b<!--\nmulti\nline-->c<!-- open"}')
  model_sandbox_validate_verdict "$vf" "$SHA"
  [ "$(jq -r .body "$vf" | tail -n1)" = "abc" ]
  jq -r .body "$vf" | head -n1 | grep -q 'decision=escalated risk=MEDIUM'
}

@test "the validated verdict passes the posting guard's marker check" {
  local vf; vf=$(verdict '{"decision":"approve","risk":"HIGH","body":"fine"}')
  model_sandbox_validate_verdict "$vf" "$SHA"
  local body pattern
  body=$(jq -r .body "$vf")
  pattern="<!-- pr-review-agent v1 sha=${SHA}[[:space:]][^>]*decision=approved[^>]*-->"
  [[ "$body" =~ $pattern ]]
}

@test "unknown fields are dropped and flags must be real booleans" {
  local vf; vf=$(verdict '{"decision":"escalate","risk":"LOW","body":"x","metadata_only":"true","escalate_to_ai":1,"extra":"y","sha":"bbbb"}')
  model_sandbox_validate_verdict "$vf" "$SHA"
  [ "$(jq -r .metadata_only "$vf")" = "false" ]
  [ "$(jq -r .escalate_to_ai "$vf")" = "false" ]
  [ "$(jq -r .sha "$vf")" = "$SHA" ]
  [ "$(jq 'has("extra")' "$vf")" = "false" ]
}

@test "a skip verdict needs no body or risk" {
  local vf; vf=$(verdict '{"decision":"skip","reason":"draft"}')
  model_sandbox_validate_verdict "$vf" "$SHA"
  [ "$(jq -r .reason "$vf")" = "draft" ]
}

@test "malformed verdicts are refused" {
  local bad
  for bad in '{"decision":"merge","risk":"LOW","body":"x"}' \
             '{"decision":"approve","risk":"NONE","body":"x"}' \
             '{"decision":"approve","risk":"LOW"}' \
             '{"decision":"approve","risk":"LOW","body":42}' \
             '["approve"]' 'not json'; do
    local vf; vf=$(verdict "$bad")
    run model_sandbox_validate_verdict "$vf" "$SHA"
    [ "$status" -eq 1 ] || { echo "accepted: $bad" >&2; false; }
  done
}

@test "a verdict that is a symlink is refused" {
  echo '{"decision":"skip"}' > "$TEST_DIR/target"
  ln -s "$TEST_DIR/target" "$TEST_DIR/link.json"
  run model_sandbox_validate_verdict "$TEST_DIR/link.json" "$SHA"
  [ "$status" -eq 1 ]
}

@test "an oversized verdict is refused" {
  jq -n --arg b "$(head -c 300000 /dev/zero | tr '\0' a)" '{decision:"approve",risk:"LOW",body:$b}' > "$TEST_DIR/big.json"
  run model_sandbox_validate_verdict "$TEST_DIR/big.json" "$SHA"
  [ "$status" -eq 1 ]
}

@test "a body too long to post is refused" {
  jq -n --arg b "$(head -c 70000 /dev/zero | tr '\0' a)" '{decision:"approve",risk:"LOW",body:$b}' > "$TEST_DIR/long.json"
  run model_sandbox_validate_verdict "$TEST_DIR/long.json" "$SHA"
  [ "$status" -eq 1 ]
}

@test "a verdict carrying a credential value is refused, and the value is not printed" {
  local vf; vf=$(verdict "{\"decision\":\"approve\",\"risk\":\"LOW\",\"body\":\"see $CLAUDE_CODE_OAUTH_TOKEN\"}")
  run model_sandbox_validate_verdict "$vf" "$SHA"
  [ "$status" -eq 1 ]
  [[ "$output" != *"secretvalue"* ]]
}

# ── Pre-fed extras ───────────────────────────────────────────────────────────

extras_gh_stub() {
  cat > "$TEST_DIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
args="$*"
case "$args" in
  "pr view 7 -R combsmith/example --json closingIssuesReferences"*) [ -n "${LINKED:-}" ] && printf '%s\n' "$LINKED"; exit "${PR_VIEW_RC:-0}" ;;
  "issue view 3 -R combsmith/example"*) printf '**Title** (OPEN)\n\nIssue text\n'; exit 0 ;;
  "api repos/combsmith/example/compare/"*) printf 'a commit message\nscripts/x.sh\n'; exit 0 ;;
esac
exit 1
STUB
  chmod +x "$TEST_DIR/bin/gh"
}

@test "extras hold the linked issues and the changes since the prior review" {
  extras_gh_stub
  export LINKED="combsmith/example 3"
  prefetch_review_extras "$PR_URL" "$SHA" "abc123" "$TEST_DIR/ctx"
  [ "$PR_CONTEXT_EXTRAS_FILE" = "$TEST_DIR/ctx/pr-context-extras.md" ]
  grep -q 'Issue text' "$PR_CONTEXT_EXTRAS_FILE"
  grep -q 'scripts/x.sh' "$PR_CONTEXT_EXTRAS_FILE"
}

@test "extras say so when a fetch fails, instead of looking empty" {
  extras_gh_stub
  export PR_VIEW_RC=1
  prefetch_review_extras "$PR_URL" "$SHA" "" "$TEST_DIR/ctx"
  grep -q 'Could not be fetched' "$PR_CONTEXT_EXTRAS_FILE"
}

# ── Wiring ───────────────────────────────────────────────────────────────────

@test "the workflow requires the sandbox and sets it up before reviewing" {
  local wf="$REPO_ROOT/.github/workflows/pr-review.yml"
  grep -qE '^ +PR_REVIEW_MODEL_USER: pr-review-model$' "$wf"
  grep -qE '^ +PR_REVIEW_REQUIRE_MODEL_SANDBOX: "true"$' "$wf"
  local setup enumerate cascade install
  install=$(grep -n 'name: Install review engine CLIs' "$wf" | cut -d: -f1)
  setup=$(grep -n 'name: Set up the model sandbox' "$wf" | cut -d: -f1)
  enumerate=$(grep -n 'name: Enumerate candidate PRs' "$wf" | cut -d: -f1)
  cascade=$(grep -n 'name: Review each PR' "$wf" | cut -d: -f1)
  [ "$install" -lt "$setup" ] && [ "$setup" -lt "$enumerate" ] && [ "$enumerate" -lt "$cascade" ]
}

@test "the agent checkout keeps no credential" {
  sed -n '/name: Checkout agent repo/,/^      - name:/p' "$REPO_ROOT/.github/workflows/pr-review.yml" \
    | sed '$d' | grep -qE '^ +persist-credentials: false$'
}

@test "every model verdict reaches the output channel through post_verdict" {
  local script="$REPO_ROOT/scripts/review-one-pr.sh"
  [ "$(grep -c 'post_verdict "\$VERDICT_JSON"' "$script")" -eq 3 ]
  run grep -n 'bash "\$REVIEW_OUTPUT_CHANNEL" "\$PR_URL" "\$VERDICT_JSON"' "$script"
  [ "$status" -eq 1 ]
}

# ── Handing a verdict to the output channel ──────────────────────────────────

load_post_verdict() {
  # shellcheck source=/dev/null
  source <(sed -n '/^post_verdict() {/,/^}/p' "$REPO_ROOT/scripts/review-one-pr.sh")
  export REVIEW_OUTPUT_CHANNEL="$TEST_DIR/channel.sh" DRY_RUN=false CHANNEL_LOG="$TEST_DIR/channel.log"
  cat > "$REVIEW_OUTPUT_CHANNEL" <<'STUB'
#!/usr/bin/env bash
cp "$2" "$CHANNEL_LOG"
exit "${CHANNEL_RC:-0}"
STUB
}

@test "post_verdict reaps, validates, then posts the normalized verdict" {
  load_post_verdict
  local vf; vf=$(verdict '{"decision":"approve","risk":"LOW","body":"<!-- forged -->fine"}')
  post_verdict "$vf"
  grep -q 'pkill -KILL -u pr-review-model' "$SUDO_LOG"
  jq -r .body "$CHANNEL_LOG" | grep -q "sha=$SHA decision=approved"
  run grep -q forged "$CHANNEL_LOG"
  [ "$status" -eq 1 ]
}

@test "post_verdict never reaches the output channel with an invalid verdict" {
  load_post_verdict
  local vf; vf=$(verdict '{"decision":"merge","risk":"LOW","body":"x"}')
  run post_verdict "$vf"
  [ "$status" -eq 1 ]
  [ ! -e "$CHANNEL_LOG" ]
}

@test "post_verdict propagates the output channel's exit status" {
  load_post_verdict
  export CHANNEL_RC=101
  local vf; vf=$(verdict '{"decision":"escalate","risk":"LOW","body":"x"}')
  run post_verdict "$vf"
  [ "$status" -eq 101 ]
}

@test "outside the sandbox post_verdict passes the verdict through untouched" {
  load_post_verdict
  unset PR_REVIEW_MODEL_USER
  local vf; vf=$(verdict '{"decision":"approve","risk":"LOW","body":"<!-- kept -->"}')
  post_verdict "$vf"
  grep -q kept "$CHANNEL_LOG"
  [ ! -s "$SUDO_LOG" ]
}

# ── Tokens stay off command lines ────────────────────────────────────────────

@test "no script in the review path puts a bearer token on a curl command line" {
  run grep -nE -- '-H "Authorization: Bearer|--header "Authorization: Bearer' \
    "$REPO_ROOT/scripts/engine.sh" "$REPO_ROOT/scripts/review-batch.sh"
  [ "$status" -eq 1 ]
}
