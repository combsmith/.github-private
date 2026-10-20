#!/usr/bin/env bash
# Run the cascading review against every PR listed in $PRS_FILE (default
# prs.txt). One PR per line. Empty input is a no-op.
#
# Env (passed through from the workflow):
#   PRS_FILE          — path to candidate list (default: prs.txt)
#   MAX_PRS           — stop after this many actual reviews (no-ops don't count)
#   CANDIDATE_LIMIT   — hard cap on candidates inspected (timeout backstop)
#   REVIEW_ENGINE     — primary engine (claude|gemini|copilot); may follow
#                       fallback chain claude -> gemini -> copilot
#   GH_TOKEN          — workflow auth (set at job level)
#
# Exit:
#   0 — finished cleanly (zero or more reviews posted)
#   1 — session aborted early (a non-skip failure on some PR; remaining
#       candidates are deferred to the next scheduled run)

set -euo pipefail

PRS_FILE="${PRS_FILE:-prs.txt}"
MAX_PRS="${MAX_PRS:-10}"
CANDIDATE_LIMIT="${CANDIDATE_LIMIT:-100}"

# ── Engine-unavailable notice (issue #855) ──────────────────────────────────
# When every review engine (Claude → Copilot → Gemini) is rate-limited or
# unavailable for a PR, post AT MOST ONE notice comment — never a storm. The
# notice carries an HTML marker; before posting we scan the PR's existing
# comments for that marker, so a mention-dispatch retry loop that re-enters this
# batch finds the prior notice and no-ops instead of re-posting (dedupe holds
# across runs, not just within one). DRY_RUN suppresses the post. Best-effort: a
# failed/blocked post never aborts the batch — the caller's terminal handling
# (abort/continue) still runs.
ENGINE_UNAVAILABLE_MARKER='<!-- pr-review-agent engine-unavailable v1 -->'

post_engine_unavailable_notice() {
  local pr_url="$1" engine="${2:-unknown}"
  [ -z "$pr_url" ] && return 0

  if [ "${DRY_RUN:-false}" = "true" ]; then
    echo "    DRY_RUN: would post engine-unavailable notice on $pr_url"
    return 0
  fi

  # Dedupe: no-op if our notice marker is already present on this PR.
  local snapshot existing
  snapshot=$(gh pr view "$pr_url" --json comments 2>/dev/null || echo '{}')
  existing=$(jq -r --arg m "$ENGINE_UNAVAILABLE_MARKER" \
        '[(.comments // [])[] | select(.body != null) | select(.body | contains($m))] | length' \
        <<< "$snapshot" 2>/dev/null) || existing=0
  if [ "${existing:-0}" -gt 0 ] 2>/dev/null; then
    echo "::notice::Engine-unavailable notice already present on $pr_url — not re-posting"
    return 0
  fi

  local body="${ENGINE_UNAVAILABLE_MARKER}
**Automated review paused — review engines are unavailable.**

Every configured review engine (Claude → Copilot → Gemini) reported a usage/rate limit or was otherwise unavailable, so no review could be generated for this run. This is a single, deduplicated notice: the agent will re-review automatically on its next scheduled run once capacity recovers, and will not post repeat notices in the meantime."

  if gh pr comment "$pr_url" --body "$body" >/dev/null 2>&1; then
    echo "::notice::Posted single engine-unavailable notice on $pr_url (engine=$engine)"
  else
    echo "::warning::Failed to post engine-unavailable notice on $pr_url"
  fi
  return 0
}

# ── Accurate exit-100 skip reporting (issue #898) ───────────────────────────
# review-one-pr.sh returns 100 for every no-op/skip and prints a JSON verdict
# carrying the *reason* (ci-pending, already-reviewed-at-head, …). To report the
# real reason instead of a blanket "already reviewed" line — which mislabelled a
# CI-pending deferral as a completed review and made the #892 stuck-green case
# look like an idempotency deadlock — capture the reviewer's stdout per PR and
# parse the trailing reason out of it.
run_review_capture() {
  local url="$1" rc=0
  set +e
  bash scripts/review-one-pr.sh "$url" | tee "$REVIEW_OUT"
  rc=${PIPESTATUS[0]}
  set -e
  return "$rc"
}

# Extract the last "reason":"…" value from a captured review log (the verdict
# JSON is the final line review-one-pr.sh emits on a skip). Empty if none.
skip_reason_from() {
  grep -oE '"reason"[[:space:]]*:[[:space:]]*"[^"]*"' "$1" 2>/dev/null \
    | tail -n1 \
    | sed -E 's/.*"reason"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/'
}

# Pre-flight: validate engine availability before touching any PR.
# Sets CLAUDE_AVAILABLE, GEMINI_AVAILABLE, COPILOT_AVAILABLE and emits
# ::warning:: annotations + job-summary table for any unavailable engine.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=validate-engines.sh
source "$SCRIPT_DIR/validate-engines.sh"
# Engine chain (AI_ENGINES): which engines are enabled and their fallback order.
# shellcheck source=lib/engine-chain.sh
source "$SCRIPT_DIR/lib/engine-chain.sh"
validate_engines

# Short-circuit before any engine switching or smoke tests when there is
# nothing to review — avoids spurious failures if COPILOT_GITHUB_TOKEN is
# absent or invalid on a scheduled run with zero candidate PRs.
if [ ! -s "$PRS_FILE" ]; then
  echo "::notice::No candidate PRs to review."
  # Emit a summary line even for an empty queue so "0 reviews posted" can never
  # be confused with a run that found candidates and no-op'd every one of them
  # (issue #1744 AC #4). "empty queue" is the distinguishing marker.
  echo "Summary: no candidate PRs found (empty queue) — 0 reviews posted, 0 no-ops skipped, 0 failures [reviews_full=0 reviews_carried_forward=0]"
  exit 0
fi

# Primary engine: REVIEW_ENGINE when AI_ENGINES enables it, otherwise the first
# engine in AI_ENGINES — a disabled engine is never used.
_requested_engine="${REVIEW_ENGINE:-}"
REVIEW_ENGINE="$(ai_engine_primary "$_requested_engine")" || {
  echo "::error::Failed to read engine configuration file — config/ai-engines.json may be missing or unreadable"
  exit 1
}
export REVIEW_ENGINE
if [ -n "$_requested_engine" ] && [ "$_requested_engine" != "$REVIEW_ENGINE" ]; then
  _chain_msg="$(ai_engine_chain)" || {
    echo "::error::Failed to read engine configuration file — config/ai-engines.json may be missing or unreadable"
    exit 1
  }
  echo "::warning::REVIEW_ENGINE=$_requested_engine is not enabled in AI_ENGINES ($_chain_msg) — using $REVIEW_ENGINE"
fi
unset _requested_engine

# Honor the pre-flight probe: if the primary engine was flagged unavailable by
# validate_engines (e.g. Gemini credits depleted on every key, Copilot on a
# classic PAT), start the batch on the first available engine in AI_ENGINES so
# no PR invocation pays the per-call retry delay for a known-bad engine.
if ! ai_engine_available "$REVIEW_ENGINE"; then
  _start_engine="$(ai_engine_first_available)"
  if [ -n "$_start_engine" ]; then
    echo "::warning::Primary $(ai_engine_label "$REVIEW_ENGINE") engine unavailable per pre-flight probe — switching to $(ai_engine_label "$_start_engine") for this batch"
    export REVIEW_ENGINE="$_start_engine"
  elif [ "$REVIEW_ENGINE" != "claude" ]; then
    _chain_msg="$(ai_engine_chain)" || {
      echo "::error::Failed to read engine configuration file — config/ai-engines.json may be missing or unreadable"
      exit 1
    }
    echo "::error::Primary $(ai_engine_label "$REVIEW_ENGINE") engine unavailable and no other engine in AI_ENGINES ($_chain_msg) is available (e.g. Copilot fallback also unavailable: gh copilot not installed, classic PAT, or COPILOT_GITHUB_TOKEN not set) — aborting batch"
    exit 1
  else
    _chain_msg="$(ai_engine_chain)" || {
      echo "::error::Failed to read engine configuration file — config/ai-engines.json may be missing or unreadable"
      exit 1
    }
    echo "::warning::Claude unavailable per pre-flight probe and no other engine in AI_ENGINES ($_chain_msg) is available — continuing on Claude"
  fi
  unset _start_engine
fi

# ---------------------------------------------------------------------------
# Copilot REST API smoke test.
#
# Verifies GitHub Models API connectivity and auth BEFORE reviewing any PRs,
# so format/auth errors surface as a clear setup failure rather than being
# mis-classified as rate-limit hits mid-run. It probes every distinct model a
# tier will call (AI_MODELS_COPILOT gives each tier its own), so a typo in
# e.g. the deep model is caught here too. Without the models library, the one
# COPILOT_API_MODEL every tier used.
#
# _copilot_smoke_test <level> [duck] — level is `error` (Copilot is primary:
# the caller aborts the batch) or `warning` (Copilot is only a fallback: the
# caller marks it unavailable so the chain skips it). With `duck`, probes only
# the Copilot duck model, when it differs from every tier model. Returns 1 on
# the first failure.
# ---------------------------------------------------------------------------
_copilot_smoke_test() {
  local level="$1" only="${2:-}" models="" tier model payload rc raw http body text
  if declare -F ai_models_copilot_model >/dev/null 2>&1; then
    for tier in triage deep audit action single; do
      model="$(ai_models_copilot_model "$tier")"
      case " $models " in *" $model "*) ;; *) models="${models:+$models }$model" ;; esac
    done
    if [ "$only" = duck ]; then
      model="$(ai_models_copilot_model duck)"
      case " $models " in *" $model "*) return 0 ;; esac
      models="$model"
    fi
  elif [ "$only" = duck ]; then
    return 0
  fi
  if [ -z "$models" ]; then
    models="${COPILOT_API_MODEL:-}"
    if [ -z "$models" ]; then
      # shellcheck source=engine.sh
      source "$SCRIPT_DIR/engine.sh" > /dev/null || {
        echo "::$level::Copilot pre-flight: failed to source engine.sh — check REVIEW_ENGINE and file path" >&2
        return 1
      }
      models="${COPILOT_API_MODEL:-openai/o4-mini}"
    fi
  fi
  if [ -z "${COPILOT_GITHUB_TOKEN:-}" ]; then
    echo "::$level::Copilot pre-flight: COPILOT_GITHUB_TOKEN not set for copilot engine"
    return 1
  fi

  for model in $models; do
    payload=$(mktemp) || { echo "::$level::Copilot pre-flight: mktemp failed" >&2; return 1; }
    python3 -c "
import json, sys
sys.stdout.write(json.dumps({
    'model': sys.argv[1],
    'messages': [{'role': 'user', 'content': 'Reply with the single word: ready'}],
    'max_tokens': 5,
    'temperature': 0,
}))
" "$model" > "$payload" || {
      rm -f "$payload"
      echo "::$level::Copilot pre-flight: failed to build smoke-test JSON payload" >&2
      return 1
    }

    rc=0
    raw=$(
      timeout 30 curl -sSL \
        -H "Authorization: Bearer ${COPILOT_GITHUB_TOKEN}" \
        -H "Content-Type: application/json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        https://models.github.ai/inference/chat/completions \
        --data-binary @"$payload" \
        -w '\n%{http_code}'
    ) || rc=$?
    rm -f "$payload"

    if [ "$rc" -ne 0 ]; then
      echo "::$level::Copilot pre-flight failed: curl exited $rc — check COPILOT_GITHUB_TOKEN and network connectivity"
      return 1
    fi

    http=$(printf '%s' "$raw" | tail -n 1)
    body=$(printf '%s' "$raw" | head -n -1)

    if [ "$http" -ge 400 ]; then
      echo "::$level::Copilot pre-flight failed: GitHub Models API returned HTTP $http for model '${model}'"
      echo "  Response: $body"
      echo "  Check COPILOT_GITHUB_TOKEN permissions and that model '${model}' is available."
      echo "  Override the model via AI_MODELS_COPILOT or the COPILOT_API_MODEL env var if needed."
      return 1
    fi

    text=$(printf '%s' "$body" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(d.get('choices', [{}])[0].get('message', {}).get('content', '(empty)'))
" 2>/dev/null || echo "(parse failed)")
    echo "::notice::Copilot pre-flight passed — model=${model} response='${text}'"
  done
  return 0
}

if [ "${REVIEW_ENGINE:-claude}" = "copilot" ]; then
  echo "==> Copilot engine pre-flight: testing GitHub Models API"
  _copilot_smoke_test error || exit 1
elif ai_engine_available copilot && [ -n "${COPILOT_GITHUB_TOKEN:-}" ]; then
  # Copilot is an enabled fallback: probe it now, so a bad model skips Copilot
  # in the chain instead of failing a PR after the earlier engines are spent.
  echo "==> Copilot fallback pre-flight: testing GitHub Models API"
  if ! _copilot_smoke_test warning; then
    echo "::warning::Copilot fallback marked unavailable for this batch — the chain skips it"
    export COPILOT_AVAILABLE=false
  fi
fi
# A separate Copilot duck model (AI_MODELS_COPILOT duck=…) is probed on its
# own. The duck is advisory, so a failure is a warning only: it neither aborts
# the batch nor takes Copilot out of the chain, but it names the bad model
# before every PR's second opinion silently fails on it.
if ai_engine_available copilot && [ -n "${COPILOT_GITHUB_TOKEN:-}" ]; then
  _copilot_smoke_test warning duck || \
    echo "::warning::Copilot rubber-duck model unavailable — fix AI_MODELS_COPILOT duck=; reviews continue without a Copilot second opinion"
fi

actual=0
escalated=0
skipped_noops=0
carried_forward=0
deferred=0
failed=0
engine_fallbacks=0
fallback_engines=""
processed=0
session_aborted=0
abort_pr=""
abort_reason=""
total_candidates=$(grep -c . "$PRS_FILE" || true)

# Per-PR capture buffer for run_review_capture / skip_reason_from (issue #898).
# _chain_has_later_engine <engine> — 0 when AI_ENGINES lists any engine after
# <engine> (available or not).
_chain_has_later_engine() {
  local e seen=0 _chain
  _chain="$(ai_engine_chain)" || {
    echo "::error::Failed to read engine configuration file — config/ai-engines.json may be missing or unreadable" >&2
    exit 1
  }
  for e in $_chain; do
    if [ "$seen" -eq 1 ]; then
      return 0
    fi
    [ "$e" = "${1:-}" ] && seen=1
  done
  return 1
}

# Engines that hit a genuine rate limit earlier in this batch. They keep their
# *_AVAILABLE flag (the probe found them usable), but re-invoking one on a later
# PR — or as a rubber duck — only burns another call. Exported, and honoured by
# ai_engine_available, so candidate selection here and duck selection in the
# review-one-pr.sh child process both skip them.
export AI_ENGINES_RATE_LIMITED=""
_mark_rate_limited() {
  [[ " $AI_ENGINES_RATE_LIMITED " == *" $1 "* ]] || export AI_ENGINES_RATE_LIMITED="${AI_ENGINES_RATE_LIMITED:+$AI_ENGINES_RATE_LIMITED }$1"
}
_mark_unavailable() {
  case "$1" in
    claude) export CLAUDE_AVAILABLE=false ;;
    gemini) export GEMINI_AVAILABLE=false ;;
    copilot) export COPILOT_AVAILABLE=false ;;
  esac
}

# Copilot licensing/policy denial (#1546): deterministic, not a rate limit, so
# review-one-pr.sh exits non-zero rather than 2 or 55. Same phrases as
# engine.sh's _license_denied_pattern (a bats case keeps the two in sync).
_BATCH_LICENSE_DENIED_RE="(access denied by policy settings|not supported by copilot)"
# _runtime_unavailable <rc> [fallback] — exit codes that mean "this engine
# cannot run here" rather than "rate-limited": 55 (setup/runtime unavailable),
# 127 on a fallback (binary missing), or a Copilot policy denial in the output.
_runtime_unavailable() {
  local rc="$1"
  [ "$rc" -eq 55 ] && return 0
  [ "${2:-}" = fallback ] && [ "$rc" -eq 127 ] && return 0
  [ "$REVIEW_ENGINE" = copilot ] && [ "$rc" -ne 0 ] && [ "$rc" -ne 2 ] && [ "$rc" -ne 100 ] \
    && grep -qiE "$_BATCH_LICENSE_DENIED_RE" "$REVIEW_OUT" 2>/dev/null
}

REVIEW_OUT=$(mktemp) || { echo "::error::Failed to create temporary file for review capture" >&2; exit 1; }
trap 'rm -f "$REVIEW_OUT"' EXIT

while IFS= read -r pr_url; do
  [ -z "$pr_url" ] && continue
  processed=$((processed + 1))

  if [ "$processed" -gt "$CANDIDATE_LIMIT" ]; then
    echo "::notice::Hit CANDIDATE_LIMIT=$CANDIDATE_LIMIT, stopping batch"
    break
  fi
  if [ "$actual" -ge "$MAX_PRS" ]; then
    echo "::notice::Reached MAX_PRS=$MAX_PRS actual reviews, stopping batch"
    break
  fi

  echo "::group::Reviewing $pr_url"
  # An earlier PR may have marked the current engine unavailable or found it
  # rate-limited; start this PR on the first engine that is still usable. Once
  # a rate limit has hit (AI_ENGINES_RATE_LIMITED non-empty) and nothing usable is
  # left, stop the session instead of re-invoking an exhausted engine per PR.
  if ! ai_engine_available "$REVIEW_ENGINE"; then
    _start_engine="$(ai_engine_first_available)"
    if [ -n "$_start_engine" ]; then
      echo "::notice::$(ai_engine_label "$REVIEW_ENGINE") unavailable or rate-limited earlier in this batch — reviewing on $(ai_engine_label "$_start_engine")"
      export REVIEW_ENGINE="$_start_engine"
    elif [ -n "$AI_ENGINES_RATE_LIMITED" ]; then
      _chain_msg="$(ai_engine_chain)" || {
        echo "::error::Failed to read engine configuration file — config/ai-engines.json may be missing or unreadable" >&2
        exit 1
      }
      echo "::error::Every engine in AI_ENGINES ($_chain_msg) is rate-limited or unavailable in this batch — stopping; the next scheduled run retries"
      processed=$((processed - 1))
      session_aborted=1
      abort_pr="$pr_url"
      abort_reason="every engine rate-limited or unavailable"
      echo "::endgroup::"
      break
    fi
    unset _start_engine
  fi
  rc=0
  run_review_capture "$pr_url" || rc=$?

  # Treat known engine-unavailable setup/runtime errors as fallback-eligible
  if _runtime_unavailable "$rc"; then
    echo "::warning::Engine ${REVIEW_ENGINE:-claude} unavailable at runtime (exit $rc) — treating as fallback-eligible"
    [ "$rc" -ne 55 ] && _mark_unavailable "$REVIEW_ENGINE"
    rc=2
  elif [ "$rc" -eq 2 ]; then
    _mark_rate_limited "$REVIEW_ENGINE"
  fi

  # Exit code 2 = engine rate-limited. Walk the configured chain (AI_ENGINES,
  # default claude → gemini → copilot; #1777 put Gemini before Copilot) forward
  # from the current engine, skipping engines that are disabled or that the
  # pre-flight probe marked unavailable. The switch sticks for the remaining PRs.
  _fallback_unavailable=0
  while [ "$rc" -eq 2 ]; do
    _next_engine="$(ai_engine_next_available "$REVIEW_ENGINE")"
    [ -z "$_next_engine" ] && break
    echo "::warning::$(ai_engine_label "$REVIEW_ENGINE") rate limit hit — switching to $(ai_engine_label "$_next_engine") engine for remaining PRs"
    export REVIEW_ENGINE="$_next_engine"
    engine_fallbacks=$((engine_fallbacks + 1))
    fallback_engines="${fallback_engines:+$fallback_engines, }$_next_engine"
    rc=0
    run_review_capture "$pr_url" || rc=$?
    # Engine-unavailable setup/runtime errors on a fallback: mark the engine
    # unavailable for the rest of the batch and keep walking the chain.
    # _fallback_unavailable tracks the LAST engine tried: a later engine that
    # is genuinely rate-limited clears it, so an exhausted chain still aborts.
    _fallback_unavailable=0
    if _runtime_unavailable "$rc" fallback; then
      _fallback_unavailable=1
      echo "::warning::$(ai_engine_label "$REVIEW_ENGINE") engine unavailable at runtime (exit $rc) — trying the next engine in AI_ENGINES"
      _mark_unavailable "$REVIEW_ENGINE"
      rc=2
    elif [ "$rc" -eq 2 ]; then
      _mark_rate_limited "$REVIEW_ENGINE"
    fi
  done
  unset _next_engine

  # Still rate-limited with later engines configured but none available (e.g.
  # Gemini out of credits, Copilot on a classic PAT), or the last fallback tried
  # was unavailable at runtime rather than rate-limited: skip this PR with one
  # notice and keep the batch going. Only a genuinely rate-limited, exhausted
  # chain falls through to the session-abort branch below.
  if [ "$rc" -eq 2 ] && { _chain_has_later_engine "$REVIEW_ENGINE" || [ "$_fallback_unavailable" -eq 1 ]; }; then
    _chain_msg="$(ai_engine_chain)" || {
      echo "::error::Failed to read engine configuration file — config/ai-engines.json may be missing or unreadable" >&2
      exit 1
    }
    echo "::warning::No later engine in AI_ENGINES ($_chain_msg) is available after $(ai_engine_label "$REVIEW_ENGINE") — skipping $pr_url and continuing batch"
    post_engine_unavailable_notice "$pr_url" "$REVIEW_ENGINE"
    failed=$((failed + 1))
    echo "::endgroup::"
    continue
  fi

  case "$rc" in
    0)
      actual=$((actual + 1))
      echo "::notice::Review posted ($actual/$MAX_PRS)"
      ;;
    101)
      # Human-escalation (issue #1754). A decision WAS made and an artifact
      # (comment + label + CODEOWNERS request) was left on the PR, but no review
      # was posted. Count it as `escalated` — never as a posted review, and never
      # as a failure (it is a clean, expected terminal outcome).
      escalated=$((escalated + 1))
      echo "::notice::Escalated to human review ($pr_url)"
      ;;
    100)
      # Report the real skip reason instead of a blanket "already reviewed".
      # Reasons that mean "a review is still owed once checks settle" bump the
      # deferred counter so the run summary flags them (issue #898).
      reason=$(skip_reason_from "$REVIEW_OUT")
      # A carry-forward (issue #1865) rides the exit-100 sentinel so it stays off
      # the MAX_PRS budget of full reviews, but it is NOT a no-op — it re-issued
      # the prior approval at the new head SHA. Count it in its own bucket so the
      # summary reports carried-forward reviews distinctly from real no-ops (AC #6).
      if [ "$reason" = "carried-forward" ]; then
        carried_forward=$((carried_forward + 1))
        echo "::notice::Carried forward — re-issued the prior approval for a conflict-free base merge (no model tier run)"
        echo "::endgroup::"
        continue
      fi
      skipped_noops=$((skipped_noops + 1))
      case "$reason" in
        already-reviewed-at-head)
          echo "::notice::No-op — already reviewed at current head" ;;
        ci-pending|ci-pending-after-poll)
          deferred=$((deferred + 1))
          echo "::notice::Deferred — CI still pending; a review is owed once checks go green" ;;
        ci-failing)
          deferred=$((deferred + 1))
          echo "::notice::Deferred — CI failing; will re-review after fixes land" ;;
        waiting-for-advisory-bots)
          deferred=$((deferred + 1))
          echo "::notice::Deferred — awaiting advisory bot reviews" ;;
        advisory-gate-api-error)
          deferred=$((deferred + 1))
          echo "::notice::Deferred — advisory-bot gate API error; will re-evaluate next run" ;;
        changes-requested)
          echo "::notice::Skipped — human changes requested; awaiting author" ;;
        human-escalated|max-cycles-reached)
          echo "::notice::Skipped — escalated to a human reviewer" ;;
        gh-rate-limited)
          echo "::notice::Skipped — gh API rate limited; will retry next run" ;;
        *)
          echo "::notice::No-op${reason:+ — $reason}" ;;
      esac
      ;;
    2)
      failed=$((failed + 1))
      echo "::error::Rate limit hit on $REVIEW_ENGINE engine, no fallback available for $pr_url"
      post_engine_unavailable_notice "$pr_url" "$REVIEW_ENGINE"
      session_aborted=1
      abort_pr="$pr_url"
      abort_reason="rate-limit on fallback engine"
      ;;
    *)
      # Per-PR failure — log and continue. Remaining candidates still run.
      # Accumulated failures surface in the session summary.
      failed=$((failed + 1))
      echo "::error::Review failed for $pr_url (exit code $rc)"
      ;;
  esac

  echo "::endgroup::"
  [ "$session_aborted" -eq 1 ] && break
done < "$PRS_FILE"

remaining=$((total_candidates - processed))
summary="Summary: $actual reviews posted, $escalated escalated to human, $skipped_noops no-ops skipped, $failed failures"
# Deterministic carry-forward observability (issue #1865 AC #6): always emit both
# counters, even when zero, so a run's full-vs-carried split is machine-parseable.
# reviews_full is the count of full (model-tier) reviews posted (= $actual).
summary="$summary [reviews_full=$actual reviews_carried_forward=$carried_forward]"
[ "$carried_forward" -gt 0 ] && summary="$summary, $carried_forward carried forward (conflict-free base merges, no tier run)"
[ "$engine_fallbacks" -gt 0 ] && summary="$summary, $engine_fallbacks engine fallback(s) to $fallback_engines"
[ "$deferred" -gt 0 ] && summary="$summary ($deferred deferred pending CI/checks — owed a review once green)"
summary="$summary (processed $processed/$total_candidates candidates)"

if [ "$session_aborted" -eq 1 ]; then
  echo "::error::Session aborted early after failure on $abort_pr ($abort_reason). Skipped $remaining remaining candidate(s); will retry on next scheduled run."
  echo "$summary [SESSION ABORTED EARLY]"
  exit 1
fi

echo "$summary"
[ "$failed" -gt 0 ] && exit 1
exit 0
