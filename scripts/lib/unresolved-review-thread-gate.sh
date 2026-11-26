#!/usr/bin/env bash
# Unresolved review-thread gate (issue #1766)
#
# Mechanical enforcement of decision gate 4 ("No unresolved review threads
# requesting changes", prompts/shared.md). Gate 4 was stated in the prompt but
# only advisory: the cascade posted APPROVED on PR #1742 while 15 review threads
# were unresolved, contradicting its own gate — and the `required_review_thread_
# resolution` ruleset (the ONLY thing then preventing merge) still blocked the
# merge, so the approval was both wrong and misleading.
#
# This gate makes gate 4 a hard, server-verifiable precondition on an APPROVE
# verdict. It is distinct from the #1415 maintainer review-thread gate:
#   • The maintainer gate (maintainer-review-thread-gate.sh) EXCLUDES advisory
#     bots (gemini-code-assist, coderabbitai, …) because those threads are the
#     dev-lead fix-cycle's responsibility, not a human maintainer's finding.
#     On PR #1742 all 15 unresolved threads were exactly those excluded bots, so
#     that gate correctly let the PR through — it is not gate 4.
#   • This gate is AUTHOR-AGNOSTIC. It counts every unresolved review thread,
#     the same unit `required_review_thread_resolution` uses to block merge, so
#     an APPROVE while any thread is unresolved is impossible. Once the fix-cycle
#     resolves the threads (isResolved == true) the gate clears — no deadlock.
#
# The gate FAILS CLOSED (#1766 AC #2): if the thread set cannot be fully
# enumerated (API failure, permissions, or pagination beyond the first page), an
# unknown count must NEVER read as zero — it withholds approval and escalates.
#
# check_unresolved_review_threads returns:
#   0 = enumeration is complete AND zero threads are unresolved → approval allowed
#   1 = one or more unresolved review threads → withhold approval (escalate)
#   2 = the snapshot cannot be evaluated (missing/empty/malformed/incomplete
#       enumeration) → fail closed (escalate)
#
# The check is pure jq (no gh/network). urtg_fetch_review_threads() is the thin
# gh helper the caller uses to obtain <threads_json>.

# set -euo pipefail is intentionally omitted at the top level: this file is
# sourced, and setting shell options would leak into the calling script. It is
# enabled only in the standalone execution block below.

_URTG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=open-review-threads.sh
source "$_URTG_DIR/open-review-threads.sh"

# log_unresolved_gate_info <message...>
#   Echo an info-level message to stderr with [unresolved-review-gate] prefix.
#   Used for operational diagnostics (e.g., gate check results) that should appear
#   in the GitHub Actions log without triggering alerts. All output goes to stderr.
log_unresolved_gate_info() {
  echo "[unresolved-review-gate] $*" >&2
}

# log_unresolved_gate_warn <message...>
#   Echo a warning-level message to stderr with [unresolved-review-gate] WARNING prefix.
#   Used for gate-blocking conditions (e.g., unresolved threads, fetch failures) that
#   may indicate decisions being withheld or escalated. All output goes to stderr.
log_unresolved_gate_warn() {
  echo "[unresolved-review-gate] WARNING: $*" >&2
}

# urtg_fetch_review_threads <pr_url>
#   Echo a JSON object {"complete": <bool>, "reviewThreads": [ {isResolved}, … ]}.
#   Delegates to ort_fetch_open_threads (lib/open-review-threads.sh), which pages
#   through EVERY review thread (so a PR with more than 100 threads can still
#   clear the gate) and fails closed. `reviewThreads` holds the unresolved
#   threads; `complete` is true only when every page was fetched and validated.
#   On any failure (unparseable URL, API error, malformed page, missing cursor)
#   `complete` is false so the pure check fails closed rather than under-counting.
#   Always emits a valid JSON object (never empty) so the caller can consume it
#   with jq.
urtg_fetch_review_threads() {
  local pr_url="${1:-}"
  local _fail='{"complete": false, "reviewThreads": []}'
  local _re='^https://github\.com/([^/]+/[^/]+)/pull/([0-9]+)/?$'
  if [[ ! "$pr_url" =~ $_re ]]; then
    log_unresolved_gate_warn "cannot parse PR URL '$pr_url' — failing closed"
    printf '%s' "$_fail"
    return 0
  fi
  local _repo="${BASH_REMATCH[1]}" _pr="${BASH_REMATCH[2]}"
  local _open
  if ! _open=$(ort_fetch_open_threads "$_repo" "$_pr"); then
    log_unresolved_gate_warn "review-threads enumeration failed — failing closed"
    printf '%s' "$_fail"
    return 0
  fi
  jq -cn --argjson t "$_open" '{complete: true, reviewThreads: $t}' 2>/dev/null \
    || printf '%s' "$_fail"
}

# check_unresolved_review_threads <threads_json>
#   Evaluate a threads snapshot (from urtg_fetch_review_threads) and return a
#   verdict indicating whether approval may proceed. This is a pure check (no
#   network I/O) that fails closed: an unknown or incomplete count is never
#   treated as zero, to prevent approval while threads remain unresolved (issue
#   #1766, decision gate 4).
#
#   Returns:
#     0 = snapshot is complete AND zero unresolved threads → approval allowed
#     1 = one or more unresolved review threads → withhold approval (escalate)
#     2 = snapshot cannot be fully evaluated (incomplete, malformed, or missing)
#         → fail closed (escalate). An unknown thread count must never read as zero.
check_unresolved_review_threads() {
  local json="${1:-}"

  if [[ -z "$json" ]]; then
    log_unresolved_gate_warn "review-threads snapshot is empty — failing closed (blocking approval)"
    return 2
  fi

  # Compute a single verdict token with jq. A malformed snapshot exits non-zero
  # → return 2. A snapshot that is not a complete enumeration ("incomplete") or
  # not an object ("err") also fails closed. Otherwise emit the count of threads
  # whose isResolved is not exactly true (a thread missing the field is treated
  # as unresolved — fail closed per-thread). reviewThreads MUST be an array.
  local verdict
  verdict=$(printf '%s' "$json" | jq -r '
    if (type != "object") then "err"
    elif (.complete != true) then "incomplete"
    elif ((.reviewThreads | type) != "array") then "err"
    else ([ (.reviewThreads)[] | select(.isResolved != true) ] | length | tostring)
    end
  ' 2>/dev/null) || {
    log_unresolved_gate_warn "could not parse review-threads snapshot — failing closed (blocking approval)"
    return 2
  }

  case "$verdict" in
    err|incomplete|"")
      log_unresolved_gate_warn "review-threads snapshot could not be fully enumerated (API failure, permissions, or pagination) — failing closed (blocking approval)"
      return 2
      ;;
  esac

  if ! [[ "$verdict" =~ ^[0-9]+$ ]]; then
    log_unresolved_gate_warn "review-threads snapshot produced malformed verdict '$verdict' — failing closed (blocking approval)"
    return 2
  fi

  if [[ "$verdict" -gt 0 ]]; then
    log_unresolved_gate_warn "$verdict unresolved review thread(s) — withholding approval (decision gate 4, #1766)"
    return 1
  fi

  log_unresolved_gate_info "no unresolved review threads"
  return 0
}

# Run standalone against a PR URL (only if executed, not sourced).
if [[ "${BASH_SOURCE[0]}" = "${0}" ]]; then
  set -euo pipefail
  _pr_url="${1:-}"
  if [[ -z "$_pr_url" ]]; then
    echo "usage: unresolved-review-thread-gate.sh <pr-url>" >&2
    exit 2
  fi
  _threads=$(urtg_fetch_review_threads "$_pr_url")
  check_unresolved_review_threads "$_threads"
  exit $?
fi
