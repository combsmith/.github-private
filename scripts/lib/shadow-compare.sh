#!/usr/bin/env bash
# shadow-compare.sh — shadow-mode dual-run comparison + promotion signal (#605).
#
# Shadow-mode runs the `next`-channel agent in parallel with the `stable` agent on
# the same PR: only `stable`'s output is posted to the PR, while `next` runs as a
# silent shadow whose output is logged and compared against `stable`. The
# comparison yields a quality-regression signal that the health-gated promotion
# gate (#501) consumes as a required input before advancing a candidate ring.
# This unblocks the self-improving-skills proposer (#587), which gates on a safe
# canary; it is part of the Safe Release Strategy (#495).
#
# This library is PURE — sourced by the wrapper (scripts/shadow-run.sh) and by
# tests. No network, no agent dispatch, no side effects. The wrapper owns I/O.
#
# Classification (sc_classify), stable-vs-shadow on the same PR:
#   MATCH          both succeed, outputs equal after normalization — strongest
#                  healthy signal (candidate reproduces production exactly)
#   DIVERGED       both succeed but outputs differ — ADVISORY only. Review quality
#                  is not objectively measurable (A/B quality routing is deferred,
#                  see docs/initiatives/agentic-release-strategy.md §5/Option D),
#                  so a divergence is logged for human review but does not block.
#   REGRESSION     stable succeeds but shadow does not (failed/empty/errored) —
#                  the candidate did demonstrably worse than production on the same
#                  input. This is the one BLOCKING signal for promotion.
#   SHADOW_ONLY_OK stable did not succeed but shadow did — the candidate may be a
#                  fix; do not block promotion on an unrelated stable failure.
#   BOTH_FAILED    neither succeeded — environmental / PR-specific, not attributable
#                  to the candidate. Inconclusive, non-blocking.
#   NO_SHADOW      no shadow run was observed — inconclusive, non-blocking.
#
# Only REGRESSION blocks promotion (sc_is_blocking); every other status is
# healthy, advisory, or inconclusive. This keeps the gate conservative: it halts a
# candidate only when it is provably worse than the version it would replace.

SC_SIGNAL_TYPE="shadow_dual_run"

# sc_normalize <text> — strip leading/trailing whitespace (incl. newlines) so two
# outputs differing only by surrounding whitespace compare equal. Pure.
sc_normalize() {
  local text="${1:-}"
  # Trim leading whitespace (including newlines), then trailing whitespace.
  text="${text#"${text%%[![:space:]]*}"}"
  text="${text%"${text##*[![:space:]]}"}"
  printf '%s' "$text"
}

# sc_conclusion_ok <conclusion> — return 0 iff the run concluded success.
sc_conclusion_ok() {
  [[ "${1:-}" = "success" ]]
}

# sc_conclusion_present <conclusion> — return 0 iff a run was actually observed.
# Empty/"null" means no run happened; "skipped" means the lane was gated off
# (conditional/paths filter) and never executed — both are "no shadow run", so
# they classify as NO_SHADOW (inconclusive), NOT a REGRESSION false-positive.
sc_conclusion_present() {
  case "${1:-}" in
    ""|null|skipped) return 1 ;;
    *)               return 0 ;;
  esac
}

# sc_classify <stable_conclusion> <shadow_conclusion> <stable_out> <shadow_out>
# Echo one status token (see header). Pure.
sc_classify() {
  local stable_concl="${1:-}" shadow_concl="${2:-}"
  local stable_out="${3:-}" shadow_out="${4:-}"

  # No shadow run at all — nothing to compare, inconclusive.
  if ! sc_conclusion_present "$shadow_concl"; then
    printf '%s' "NO_SHADOW"
    return 0
  fi

  local stable_ok=1 shadow_ok=1
  sc_conclusion_ok "$stable_concl" && stable_ok=0
  sc_conclusion_ok "$shadow_concl" && shadow_ok=0

  if [[ "$stable_ok" -eq 0 ]] && [[ "$shadow_ok" -eq 0 ]]; then
    # Both concluded success — compare the actual outputs.
    local sn hn
    sn="$(sc_normalize "$stable_out")"
    hn="$(sc_normalize "$shadow_out")"
    # A shadow that "succeeds" but emitted nothing where stable produced output is
    # a silent regression, not a match.
    if [[ -z "$hn" ]] && [[ -n "$sn" ]]; then
      printf '%s' "REGRESSION"
    elif [[ "$sn" = "$hn" ]]; then
      printf '%s' "MATCH"
    else
      printf '%s' "DIVERGED"
    fi
    return 0
  fi

  if [[ "$stable_ok" -eq 0 ]] && [[ "$shadow_ok" -ne 0 ]]; then
    printf '%s' "REGRESSION"
    return 0
  fi

  if [[ "$stable_ok" -ne 0 ]] && [[ "$shadow_ok" -eq 0 ]]; then
    printf '%s' "SHADOW_ONLY_OK"
    return 0
  fi

  printf '%s' "BOTH_FAILED"
}

# sc_is_blocking <status> — return 0 iff the status must block promotion. Only a
# REGRESSION blocks; every other status is healthy/advisory/inconclusive.
sc_is_blocking() {
  [[ "${1:-}" = "REGRESSION" ]]
}

# sc_signal_json <status> <reusable> <channel> <stable_run_id> <shadow_run_id>
# Emit the compact JSON signal the #501 promotion gate reads. Run ids are numeric
# when present and null when absent. Pure (uses jq for correct escaping/typing).
sc_signal_json() {
  local status="${1:-}" reusable="${2:-}" channel="${3:-}"
  local stable_run_id="${4:-}" shadow_run_id="${5:-}"
  local blocking=false regression=false
  if sc_is_blocking "$status"; then
    blocking=true
    regression=true
  fi

  jq -cn \
    --arg signal "$SC_SIGNAL_TYPE" \
    --arg reusable "$reusable" \
    --arg channel "$channel" \
    --arg status "$status" \
    --argjson regression "$regression" \
    --argjson blocks "$blocking" \
    --arg stable_run_id "$stable_run_id" \
    --arg shadow_run_id "$shadow_run_id" \
    '{
      signal: $signal,
      reusable: $reusable,
      channel: $channel,
      status: $status,
      regression: $regression,
      blocks_promotion: $blocks,
      stable_run_id: (($stable_run_id | tonumber?) // null),
      shadow_run_id: (($shadow_run_id | tonumber?) // null)
    }'
}

# sc_report <status> <reusable> <channel> <stable_run_url> <shadow_run_url> [today]
# Markdown body for the workflow log / step summary. This is NEVER posted to the
# PR — only stable's output reaches the PR; the shadow lane is silent. Pure.
sc_report() {
  local status="${1:-}" reusable="${2:-}" channel="${3:-}"
  local stable_url="${4:-}" shadow_url="${5:-}" today="${6:-}"
  [[ -n "$today" ]] || today="$(date -u +%Y-%m-%d)"

  local icon headline
  case "$status" in
    MATCH)          icon='✅'; headline='shadow reproduced stable exactly' ;;
    DIVERGED)       icon='🟡'; headline='shadow diverged from stable (advisory — logged for human review)' ;;
    REGRESSION)     icon='🔴'; headline='shadow did worse than stable (blocks promotion)' ;;
    SHADOW_ONLY_OK) icon='🟢'; headline='shadow succeeded where stable did not (candidate may be a fix)' ;;
    BOTH_FAILED)    icon='⚪'; headline='both lanes failed (inconclusive — likely environmental)' ;;
    NO_SHADOW)      icon='⚪'; headline='no shadow run observed (inconclusive)' ;;
    *)              icon='⚪'; headline="unknown status: ${status}" ;;
  esac

  printf '# %s Shadow-mode dual-run — %s\n\n' "$icon" "$today"
  printf '_Reusable `%s` · candidate channel `%s` · signal `%s`_\n\n' \
    "$reusable" "$channel" "$SC_SIGNAL_TYPE"
  printf -- '- **Result:** %s — %s\n' "$status" "$headline"
  if sc_is_blocking "$status"; then
    printf -- '- **Promotion:** BLOCKED — this is a required health-gate signal (#501).\n'
  else
    printf -- '- **Promotion:** not blocked by this signal.\n'
  fi
  [[ -n "$stable_url" ]] && printf -- '- **Stable run:** %s\n' "$stable_url"
  [[ -n "$shadow_url" ]] && printf -- '- **Shadow run:** %s\n' "$shadow_url"
  printf '\n'
  printf '> The shadow (`%s`) output is **not posted** to the PR — only the `stable` ' "$channel"
  printf 'lane posts. The shadow output is logged and compared here for '
  printf 'quality-regression detection feeding health-gated promotion.\n'
}
