#!/usr/bin/env bash
# spec-drift.sh — deterministic spec-drift detector for the initiative pipeline
# (#1144, epic #1142).
#
# Why: a story's `acceptance_criteria` are the machine-readable spec it commits
# to (they come from scripts/initiative-planner/plan.schema.json and are
# rendered into each story issue body by scripts/initiative-planner/apply-plan.sh).
# Once the story's PR merges, shipped code can silently diverge from that spec.
# This script compares a merged PR's diff against the closed story's acceptance
# criteria and emits a structured drift verdict: DRIFT / ALIGNED / INDETERMINATE.
#
# Layout mirrors scripts/mcp_connectivity_check.sh:
#   * classify_drift / parse_acceptance_criteria / story_is_initiative /
#     drift_verdict_envelope are PURE (no network, no LLM) and unit-tested in
#     tests/test_spec_drift.bats. The eval harness (next story) calls the pure
#     classifier directly.
#   * main() does all I/O: resolve the story ACs + PR diff, invoke the cheap
#     no-tool review tier (run_triage from scripts/engine.sh), classify, emit.
#
# Fail Loud, Never Fake: when the source story's acceptance criteria cannot be
# resolved (not an initiative story, or no ACs found), the script is INERT — it
# emits INDETERMINATE, exits 0, and never fabricates a DRIFT/ALIGNED verdict.
#
# Env vars consumed:
#   SPEC_DRIFT_STORY   source story issue number (the closed story whose ACs are
#                      the spec). Without it the script is inert (INDETERMINATE).
#   SPEC_DRIFT_PR      merged PR number whose diff is compared against the ACs.
#   SPEC_DRIFT_REPO    repo slug (owner/name) for gh; falls back to GH_REPO / REPO
#                      / the ambient gh default.
#   SPEC_DRIFT_OUT     optional path; the verdict envelope is written there too.
#   TRIAGE_TIMEOUT_SEC honored by run_triage (engine.sh default 300s).
#   REVIEW_ENGINE / ENGINE_* — engine.sh routing knobs (defaults applied there).

set -euo pipefail

SPEC_DRIFT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Pure helpers (unit-tested; no network, no LLM)
# ---------------------------------------------------------------------------

# parse_acceptance_criteria <issue_body>
# Emits the acceptance-criteria list items (one per line, numbering stripped)
# from the story body's `## Acceptance Criteria` section, exactly as rendered
# by scripts/initiative-planner/apply-plan.sh. Empty output when the section is
# absent or has no numbered items. Pure: reads only its argument.
parse_acceptance_criteria() {
  local body="${1:-}"
  printf '%s\n' "$body" | awk '
    /^##[[:space:]]+Acceptance Criteria[[:space:]]*$/ { insec=1; next }
    /^##[[:space:]]/ { insec=0 }
    insec && match($0, /^[[:space:]]*[0-9]+\.[[:space:]]+/) {
      print substr($0, RLENGTH + 1)
    }
  '
}

# story_is_initiative <issue_body>
# Exit 0 when the body has the BMAD initiative-story shape (both a `## Story`
# and a `## Acceptance Criteria` section, as apply-plan.sh renders). Exit 1
# otherwise. Pure.
story_is_initiative() {
  local body="${1:-}"
  printf '%s\n' "$body" | grep -qE '^##[[:space:]]+Story[[:space:]]*$' \
    && printf '%s\n' "$body" | grep -qE '^##[[:space:]]+Acceptance Criteria[[:space:]]*$'
}

# classify_drift <analysis>
# Maps the cheap-tier drift analysis into a verdict:
#   DRIFT         — the analysis carries an explicit `DRIFT_VERDICT: DRIFT` token
#   ALIGNED       — the analysis carries an explicit `DRIFT_VERDICT: ALIGNED` token
#   INDETERMINATE — neither token present (empty/garbled/timeout). For a detector
#                   this is the honest answer, not a fabricated pass/fail.
# DRIFT is checked first, so it wins if both tokens somehow appear (fail toward
# flagging drift rather than silently passing). Pure: greps only its argument.
classify_drift() {
  local analysis="${1:-}"
  if printf '%s' "$analysis" | grep -qiE 'drift[_ ]?verdict[[:space:]]*[:=][[:space:]]*drift\b'; then
    echo "DRIFT"
    return 0
  fi
  if printf '%s' "$analysis" | grep -qiE 'drift[_ ]?verdict[[:space:]]*[:=][[:space:]]*aligned\b'; then
    echo "ALIGNED"
    return 0
  fi
  echo "INDETERMINATE"
}

# drift_verdict_envelope <verdict> <pr> <story> <reason> [now]
# Emits the compact JSON verdict envelope a downstream workflow consumes without
# re-parsing prose. Empty pr/story render as JSON null. Pure: uses jq only.
drift_verdict_envelope() {
  local verdict="${1:-INDETERMINATE}" pr="${2:-}" story="${3:-}" reason="${4:-}"
  local now
  now="${5:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
  jq -nc \
    --arg verdict "$verdict" \
    --arg pr "$pr" \
    --arg story "$story" \
    --arg reason "$reason" \
    --arg now "$now" \
    '{
      verdict: $verdict,
      pr: (if $pr == "" then null else ($pr | try tonumber catch null) end),
      story: (if $story == "" then null else ($story | try tonumber catch null) end),
      reason: $reason,
      generated_at: $now
    }'
}

# build_drift_prompt <acceptance_criteria> <pr_diff>
# Composes the cheap-tier prompt: the story's ACs (the spec) plus the merged PR
# diff, with an explicit instruction to end on a single machine-readable
# `DRIFT_VERDICT:` token that classify_drift consumes. Pure.
build_drift_prompt() {
  local acs="${1:-}" diff="${2:-}"
  cat <<PROMPT
You are a spec-drift detector. Compare a merged pull request's diff against the
acceptance criteria (the spec) the source story committed to, and decide whether
the shipped code DRIFTED from that spec or is ALIGNED with it.

Judge ONLY whether the diff satisfies the acceptance criteria as written. Do not
invent new requirements. Minor stylistic differences are ALIGNED; a criterion
left unimplemented, contradicted, or replaced by something materially different
is DRIFT.

Reply with a brief justification, then end your reply with EXACTLY ONE line, on
its own, in this form (no other text after it):
DRIFT_VERDICT: DRIFT
or
DRIFT_VERDICT: ALIGNED

=== ACCEPTANCE CRITERIA (the spec) ===
${acs}

=== MERGED PR DIFF ===
${diff}
PROMPT
}

# ---------------------------------------------------------------------------
# I/O (main)
# ---------------------------------------------------------------------------

# _emit_verdict <verdict> <pr> <story> <reason>
# Renders the envelope, prints it to stdout, and mirrors it to SPEC_DRIFT_OUT /
# GITHUB_STEP_SUMMARY when set. Always the single stdout contract.
_emit_verdict() {
  local envelope
  envelope="$(drift_verdict_envelope "$1" "$2" "$3" "$4")"
  printf '%s\n' "$envelope"
  [[ -n "${SPEC_DRIFT_OUT:-}" ]] && printf '%s\n' "$envelope" > "$SPEC_DRIFT_OUT"
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    local fence='```'
    printf '%sjson\n%s\n%s\n' "$fence" "$envelope" "$fence" >> "$GITHUB_STEP_SUMMARY"
  fi
  return 0
}

main() {
  local repo pr story
  repo="${SPEC_DRIFT_REPO:-${GH_REPO:-${REPO:-}}}"
  pr="${SPEC_DRIFT_PR:-}"
  story="${SPEC_DRIFT_STORY:-}"

  if ! command -v jq >/dev/null 2>&1; then
    echo "::error::[spec-drift] jq CLI not found — cannot emit a verdict envelope" >&2
    return 1
  fi
  if ! command -v gh >/dev/null 2>&1; then
    echo "::error::[spec-drift] gh CLI not found — cannot resolve story/PR" >&2
    return 1
  fi

  # No source story → cannot resolve the spec. Inert (Fail Loud, Never Fake).
  if [[ -z "$story" ]]; then
    echo "::notice::[spec-drift] no source story provided — inert INDETERMINATE" >&2
    _emit_verdict "INDETERMINATE" "$pr" "" "no source story provided"
    return 0
  fi

  local gh_repo_args=()
  [[ -n "$repo" ]] && gh_repo_args=(--repo "$repo")

  local body
  body="$(gh issue view "$story" "${gh_repo_args[@]}" --json body -q .body 2>/dev/null || true)"

  if [[ -z "${body//[[:space:]]/}" ]]; then
    echo "::warning::[spec-drift] could not fetch issue #${story} body (auth/network error or issue not found) — inert INDETERMINATE" >&2
    _emit_verdict "INDETERMINATE" "$pr" "$story" "could not fetch issue #${story} body"
    return 0
  fi

  # Not an initiative story, or no ACs → inert INDETERMINATE, exit 0.
  if ! story_is_initiative "$body"; then
    echo "::notice::[spec-drift] issue #${story} is not an initiative story — inert INDETERMINATE" >&2
    _emit_verdict "INDETERMINATE" "$pr" "$story" "issue #${story} is not an initiative story"
    return 0
  fi

  local acs
  acs="$(parse_acceptance_criteria "$body")"
  if [[ -z "${acs//[[:space:]]/}" ]]; then
    echo "::notice::[spec-drift] no acceptance criteria found on story #${story} — inert INDETERMINATE" >&2
    _emit_verdict "INDETERMINATE" "$pr" "$story" "no acceptance criteria found on story #${story}"
    return 0
  fi

  if [[ -z "$pr" ]]; then
    echo "::notice::[spec-drift] no merged PR provided — cannot gather a diff, inert INDETERMINATE" >&2
    _emit_verdict "INDETERMINATE" "" "$story" "no merged PR provided"
    return 0
  fi

  local diff
  diff="$(gh pr diff "$pr" "${gh_repo_args[@]}" 2>/dev/null || true)"
  if [[ -z "${diff//[[:space:]]/}" ]]; then
    echo "::notice::[spec-drift] empty or unavailable diff for PR #${pr} — inert INDETERMINATE" >&2
    _emit_verdict "INDETERMINATE" "$pr" "$story" "empty or unavailable diff for PR #${pr}"
    return 0
  fi

  # Lazy-source the engine only for the real analysis path, so the pure helpers
  # (and their tests) never drag in engine.sh. A test may pre-define run_triage
  # to exercise main() without a live engine.
  if ! declare -F run_triage >/dev/null 2>&1; then
    # shellcheck source=engine.sh
    source "$SPEC_DRIFT_DIR/engine.sh" >&2
  fi

  local prompt_file triage_stderr
  prompt_file="$(mktemp)"
  triage_stderr="$(mktemp)"
  build_drift_prompt "$acs" "$diff" > "$prompt_file"

  local analysis rc=0
  analysis="$(run_triage "$prompt_file" 2>"$triage_stderr")" || rc=$?
  [[ -s "$triage_stderr" ]] && cat "$triage_stderr" >&2
  rm -f "$prompt_file" "$triage_stderr"

  if [[ "$rc" -ne 0 ]]; then
    echo "::warning::[spec-drift] cheap-tier analysis failed (exit ${rc}) — verdict will be INDETERMINATE, not faked" >&2
  fi

  local verdict reason
  verdict="$(classify_drift "$analysis")"
  case "$verdict" in
    DRIFT)   reason="shipped diff diverges from story #${story} acceptance criteria" ;;
    ALIGNED) reason="shipped diff satisfies story #${story} acceptance criteria" ;;
    *)       reason="cheap-tier analysis produced no decisive verdict token" ;;
  esac

  echo "::notice::[spec-drift] PR #${pr} vs story #${story}: ${verdict}" >&2
  _emit_verdict "$verdict" "$pr" "$story" "$reason"
  return 0
}

# Only run main when executed directly (not when sourced by tests).
if [[ "${BASH_SOURCE[0]}" = "${0}" ]]; then
  main "$@"
fi
