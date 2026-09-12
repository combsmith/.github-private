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

set -euo pipefail

log_unresolved_gate_info() {
  echo "[unresolved-review-gate] $*" >&2
}

log_unresolved_gate_warn() {
  echo "[unresolved-review-gate] WARNING: $*" >&2
}

# urtg_fetch_review_threads <pr_url>
#   Echo a JSON object {"complete": <bool>, "reviewThreads": [ {isResolved}, … ]}.
#   `complete` is true ONLY when the GraphQL call succeeded and the PR's review
#   threads fit in a single page (pageInfo.hasNextPage == false). On any API
#   failure, an unparseable response, or a second page of threads, `complete` is
#   false so the pure check fails closed rather than under-counting. Always emits
#   a valid JSON object (never empty) so the caller can consume it with jq.
urtg_fetch_review_threads() {
  local pr_url="${1:-}"
  local _fail='{"complete": false, "reviewThreads": []}'
  if [[ -z "$pr_url" ]]; then
    printf '%s' "$_fail"
    return 0
  fi
  # shellcheck disable=SC2016  # $url is a GraphQL variable placeholder, not shell
  local _gql='query($url:URI!){resource(url:$url){...on PullRequest{reviewThreads(first:100){pageInfo{hasNextPage} nodes{isResolved}}}}}'
  local _raw
  _raw=$(gh api graphql -f query="$_gql" -f url="$pr_url" 2>/dev/null) || true
  if [[ -z "$_raw" ]]; then
    log_unresolved_gate_warn "review-threads GraphQL query returned no data — failing closed"
    printf '%s' "$_fail"
    return 0
  fi
  printf '%s' "$_raw" | jq -c '
    (.data?.resource?.reviewThreads?) as $rt
    | if $rt == null then {complete: false, reviewThreads: []}
      else {
        complete: (($rt.pageInfo?.hasNextPage // false) | not),
        reviewThreads: ($rt.nodes // [])
      } end
  ' 2>/dev/null || printf '%s' "$_fail"
}

# check_unresolved_review_threads <threads_json>
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
  # as unresolved — fail closed per-thread).
  local verdict
  verdict=$(printf '%s' "$json" | jq -r '
    if (type != "object") then "err"
    elif (.complete != true) then "incomplete"
    else ([ (.reviewThreads // [])[] | select(.isResolved != true) ] | length | tostring)
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

  if [[ "$verdict" =~ ^[0-9]+$ ]] && [[ "$verdict" -gt 0 ]]; then
    log_unresolved_gate_warn "$verdict unresolved review thread(s) — withholding approval (decision gate 4, #1766)"
    return 1
  fi

  log_unresolved_gate_info "no unresolved review threads"
  return 0
}

# Run standalone against a PR URL (only if executed, not sourced).
if [[ "${BASH_SOURCE[0]}" = "${0}" ]]; then
  _pr_url="${1:-}"
  if [[ -z "$_pr_url" ]]; then
    echo "usage: unresolved-review-thread-gate.sh <pr-url>" >&2
    exit 2
  fi
  _threads=$(urtg_fetch_review_threads "$_pr_url")
  check_unresolved_review_threads "$_threads"
  exit $?
fi
