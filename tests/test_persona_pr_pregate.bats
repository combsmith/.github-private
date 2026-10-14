#!/usr/bin/env bats
# Unit tests for the persona pull_request event pre-gate
# (scripts/persona-pr-pregate.sh + scripts/qa-lead-pr-gate.sh, issue #1905).
#
# The router-served pull_request surface reaches persona-runner-reusable.yml with
# client_payload.surface=pull_request. Before #1905 the runner ignored `surface`
# and ran the engine + posted on EVERY trusted PR — losing the persona-specific
# suppressors the local qa-lead-pr-advisory.yml gate enforces (no-test-surface,
# budget-exhausted, already-advised) on top of the router's generic brakes.
#
# `persona_event_pregate` is what the runner now calls before the engine:
#   * surface != pull_request (mention/absent) -> "run", no gate (mention path
#     unchanged, AC #1).
#   * surface == pull_request, persona qa-lead -> qa_lead_pr_gather_and_decide,
#     the ONE gathering+decision shared with the local workflow (AC #2).
#   * surface == pull_request, no registered gate -> skip + a logged notice (AC #3).
#   * any unreadable signal -> fail closed (skip) with a ::error naming it (AC #3).
#
# gh is stubbed on PATH, keyed on the `--jq` filter each call uses, so the
# gathering can be exercised offline. jq is real.
#
# Run with: bats tests/test_persona_pr_pregate.bats

setup() {
  SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/scripts/persona-pr-pregate.sh"

  # A gh stub that returns canned output keyed on the --jq filter (each distinct
  # call the gathering makes uses a distinct filter, or none for the budget
  # gather). Per-test behaviour is driven by STUB_* environment variables.
  STUB_BIN="$(mktemp -d "$BATS_TEST_TMPDIR/bin.XXXXXX")"
  cat > "$STUB_BIN/gh" <<'STUB'
#!/usr/bin/env bash
# Find the --jq filter (if any) and the repos/... url.
jqf=""; url=""; prev=""; slurp=0; tmpl=0
for a in "$@"; do
  [ "$prev" = "--jq" ] && jqf="$a"
  [ "$a" = "--slurp" ] && slurp=1
  case "$a" in --jq|--template) tmpl=1 ;; esac
  case "$a" in repos/*) [ -z "$url" ] && url="$a" ;; esac
  prev="$a"
done
# Behave like real gh: --slurp is rejected together with --jq/--template.
if [ "$slurp" = 1 ] && [ "$tmpl" = 1 ]; then
  echo "the \`--slurp\` option is not supported with \`--jq\` or \`--template\`" >&2
  exit 1
fi
case "$jqf" in
  '.changed_files')    printf '%s\n' "${STUB_CHANGED:-0}"; exit "${STUB_CHANGED_RC:-0}" ;;
  '[.labels[]?.name]') printf '%s\n' "${STUB_LABELS:-[]}"; exit "${STUB_LABELS_RC:-0}" ;;
  'if type == "array" then .[].body else error("expected comments array") end') printf '%s' "${STUB_COMMENT_BODIES:-}"; exit "${STUB_COMMENTS_RC:-0}" ;;
  '')
    # gather_pr_automation_events raw calls (no --jq, piped to jq -s downstream)
    case "$url" in
      *"/pulls/"*"/files")      # slurped: one array per page, wrapped in an outer array
                                printf '%s\n' "${STUB_FILES:-[]}" | jq -c '[map({filename: .})]' 
                                exit "${STUB_FILES_RC:-0}" ;;
      *"/issues/"*"/comments"*) printf '%s\n' "${STUB_RAW_COMMENTS:-[]}" ;;
      *"/commits"*)             printf '%s\n' "${STUB_RAW_COMMITS:-[]}" ;;
      *"/reviews"*)             printf '%s\n' "${STUB_RAW_REVIEWS:-[]}" ;;
      *) echo "::error::gh stub: unhandled url '$url'" >&2; exit 42 ;;
    esac
    exit "${STUB_GATHER_RC:-0}"
    ;;
esac
echo "::error::gh stub: unhandled --jq filter '$jqf'" >&2; exit 42
STUB
  chmod +x "$STUB_BIN/gh"
  PATH="$STUB_BIN:$PATH"

  # Defaults that pass every gate — individual tests override one signal.
  export STUB_FILES='["scripts/foo.sh"]'
  export STUB_CHANGED='1'
  export STUB_LABELS='[]'
  export STUB_COMMENT_BODIES=''
  export STUB_RAW_COMMENTS='[]'
  export STUB_RAW_COMMITS='[]'
  export STUB_RAW_REVIEWS='[]'
}

# ---------------------------------------------------------------------------
# surface absent / mention -> the mention path is unchanged (no pre-gate)
# ---------------------------------------------------------------------------

@test "AC#1: surface=mention -> run without gating (mention path unchanged)" {
  run persona_event_pregate qa-lead mention petry-projects/.github-private 5 ""
  [ "$status" -eq 0 ]
  [ "$output" = "run" ]
}

@test "AC#1: surface absent defaults to mention -> run without gating" {
  run persona_event_pregate qa-lead "" petry-projects/.github-private 5 ""
  [ "$status" -eq 0 ]
  [ "$output" = "run" ]
}

@test "AC#1: a mention dispatch never reads PR signals (no test surface needed)" {
  # Even with a docs-only PR and an unreadable file list, the mention path runs:
  # the pre-gate is a pull_request-only concern.
  STUB_FILES='["README.md"]' STUB_FILES_RC=1 \
    run persona_event_pregate qa-lead mention petry-projects/.github-private 5 ""
  [ "$status" -eq 0 ]
  [ "$output" = "run" ]
}

# ---------------------------------------------------------------------------
# An unrecognized surface is malformed dispatch data -> fail closed (skip),
# NOT treated as a mention (which would bypass every pull_request suppressor).
# ---------------------------------------------------------------------------

@test "fail-closed: an unrecognized surface skips with a ::error (not run as mention)" {
  run persona_event_pregate qa-lead bogus-surface petry-projects/.github-private 5 opened
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::"* ]]
  [[ "$output" == *skip:unknown-surface* ]]
}

# ---------------------------------------------------------------------------
# surface=pull_request, qa-lead -> the shared gather+decide
# ---------------------------------------------------------------------------

@test "run: real test surface and no suppressor" {
  run persona_event_pregate qa-lead pull_request petry-projects/.github-private 5 opened
  [ "$status" -eq 0 ]
  [ "$output" = "run" ]
}

@test "skip: no-test-surface (docs-only PR)" {
  STUB_FILES='["README.md"]' \
    run persona_event_pregate qa-lead pull_request petry-projects/.github-private 5 opened
  [ "$status" -eq 1 ]
  [[ "$output" == skip:no-test-surface* ]]
}

@test "skip: opt-out (qa-lead:hands-off label)" {
  STUB_LABELS='["qa-lead:hands-off"]' \
    run persona_event_pregate qa-lead pull_request petry-projects/.github-private 5 opened
  [ "$status" -eq 1 ]
  [[ "$output" == skip:opt-out* ]]
}

@test "skip: human-gated (needs-human-review label)" {
  STUB_LABELS='["needs-human-review"]' \
    run persona_event_pregate qa-lead pull_request petry-projects/.github-private 5 opened
  [ "$status" -eq 1 ]
  [[ "$output" == skip:human-gated* ]]
}

@test "skip: budget-exhausted (>= MAX automated actions since last human)" {
  # 10 bot comments, no human -> compute_pr_automation_cycles >= MAX (10).
  bots="$(jq -n '[range(10) | {created_at: "2026-09-20T00:00:0\(.)Z", user: {login: "github-actions[bot]"}}]')"
  STUB_RAW_COMMENTS="$bots" \
    run persona_event_pregate qa-lead pull_request petry-projects/.github-private 5 opened
  [ "$status" -eq 1 ]
  [[ "$output" == skip:budget-exhausted* ]]
}

@test "skip: already-advised (a qa-lead marker is already present)" {
  STUB_COMMENT_BODIES='<!-- persona:qa-lead -->
prior advisory' \
    run persona_event_pregate qa-lead pull_request petry-projects/.github-private 5 opened
  [ "$status" -eq 1 ]
  [[ "$output" == skip:already-advised* ]]
}

# ---------------------------------------------------------------------------
# Fail closed on an unreadable signal, naming which derivation failed (AC #3)
# ---------------------------------------------------------------------------

@test "fail-closed: unreadable changed-file list skips with a ::error" {
  STUB_FILES_RC=1 \
    run persona_event_pregate qa-lead pull_request petry-projects/.github-private 5 opened
  [ "$status" -eq 1 ]
  [[ "$output" == *skip:* ]]
  [[ "$output" == *"::error::"* ]]
  [[ "$output" == *"changed-file list unavailable"* ]]
}

@test "fail-closed: unreadable labels skips with a ::error" {
  STUB_LABELS_RC=1 \
    run persona_event_pregate qa-lead pull_request petry-projects/.github-private 5 opened
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::"* ]]
  [[ "$output" == *"labels unavailable"* ]]
}

@test "fail-closed: unreadable budget events skips with a ::error" {
  STUB_GATHER_RC=1 \
    run persona_event_pregate qa-lead pull_request petry-projects/.github-private 5 opened
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::"* ]]
  [[ "$output" == *"automation-budget events unavailable"* ]]
}

@test "fail-closed: an incomplete (truncated) changed-file list skips" {
  # Received 1 file, PR declares 5000 -> truncated -> never advise off partial data.
  STUB_CHANGED='5000' \
    run persona_event_pregate qa-lead pull_request petry-projects/.github-private 5 opened
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::"* ]]
  [[ "$output" == *"incomplete"* ]]
}

# ---------------------------------------------------------------------------
# A persona with NO registered pre-gate skips on the pull_request surface (its
# own dedicated workflow serves it), makes no gh call, and logs a notice (AC #3).
# ---------------------------------------------------------------------------

@test "no-registered-gate: skips, makes no gh call, logs a notice" {
  printf '#!/usr/bin/env bash\necho called >> "%s/gh-called"\nexit 42\n' "$BATS_TEST_TMPDIR" > "$STUB_BIN/gh"
  run persona_event_pregate scrum-master pull_request petry-projects/.github-private 5 opened
  [ "$status" -eq 1 ]
  [[ "$output" == *"skip:no-registered-pregate"* ]]
  [[ "$output" == *"::notice::"* ]]
  [[ "$output" == *"scrum-master"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/gh-called" ]
}

@test "no-registered-gate: dev-lead and pr-review also skip" {
  for p in dev-lead pr-review; do
    run persona_event_pregate "$p" pull_request petry-projects/.github-private 5 opened
    [ "$status" -eq 1 ]
    [[ "$output" == *"skip:no-registered-pregate"* ]]
  done
}

# ---------------------------------------------------------------------------
# qa_lead_pr_gather_and_decide is the ONE implementation both callers use.
# ---------------------------------------------------------------------------

@test "qa_lead_pr_gather_and_decide is defined and usable directly" {
  run qa_lead_pr_gather_and_decide petry-projects/.github-private 5
  [ "$status" -eq 0 ]
  [ "$output" = "run" ]
}
